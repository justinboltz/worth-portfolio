require "csv"
class TransactionsController < ApplicationController
  before_action :require_authentication
  before_action :load_categories
  def duplicates
    @groups = DuplicateTransactionReview.new(current_user).groups
  end

  def index
    @expense_classifier = ExpenseClassification.new(current_user)
    @search = TransactionSearch.new(user: current_user, params: params)
    scope = @search.call.includes(:account, :category, :parent, :suggested_category)
    @filter_errors = @search.errors
    @source_accounts = current_user.transactions.tracked.where.not(source_account_name: [nil, ""]).distinct.order(:source_account_name).pluck(:source_account_name)
    respond_to do |format|
      format.html do
        @total_count = scope.count
        @per_page = [25, 50, 100].include?(params[:per_page].to_i) ? params[:per_page].to_i : 50
        @page_count = [(@total_count.to_f / @per_page).ceil, 1].max
        @page = [[params[:page].to_i, 1].max, @page_count].min
        @transactions = @search.ordered(scope).offset((@page - 1) * @per_page).limit(@per_page)
        render :index, status: @filter_errors.any? ? :unprocessable_entity : :ok
      end
      format.csv do
        return render plain: @filter_errors.join(" "), status: :unprocessable_entity if @filter_errors.any?
        csv = CSV.generate do |out|
          out << %w[Date Description Amount Currency Category Account Notes Tags Hidden Duplicate Transfer CardPayment Pending SplitNeedsReview ParentID ClassificationOrigin ClassificationReason SuggestedClassification CategoryOrigin CategoryReason SuggestedCategory ExpenseType]
          @search.ordered(scope).each do |t|
            out << [t.date, t.name, t.amount.to_s("F"), t.iso_currency_code, t.category&.display_name, t.account_label, t.notes, t.tags, t.hidden? || t.parent&.hidden?, t.duplicate? || t.parent&.duplicate?, t.transfer? || t.parent&.transfer?, t.card_payment? || t.parent&.card_payment?, t.pending? || t.parent&.pending?, t.split_needs_review? || t.parent&.split_needs_review?, t.parent_id, t.classification_origin || t.parent&.classification_origin, t.classification_reason || t.parent&.classification_reason, t.suggested_classification, t.category_origin, t.category_reason, t.suggested_category&.display_name, t.amount.positive? ? ExpenseClassification::LABELS.fetch(@expense_classifier.for_transaction(t)) : nil].map { |v| v.is_a?(String) && v.match?(/\A[=+@\t\r]/) ? "'#{v}" : v }
          end
        end
        send_data csv, filename: "transactions-#{Date.current}.csv", type: "text/csv"
      end
    end
  end
  def show
    @transaction = current_user.transactions.roots.find(params[:id])
  end
  def new
    @transaction = current_user.transactions.new(source: "manual", date: Date.current, iso_currency_code: "USD")
  end
  def create
    @transaction = current_user.transactions.new(source: "manual", date: Date.current, iso_currency_code: "USD")
    @transaction.assign_attributes(category_edit_params(@transaction, transaction_params))
    @transaction.save!
    remember_merchant!(@transaction)
    CashFlowClassifier.call(user: current_user)
    AutoCategorizer.call(user: current_user)
    redirect_to transaction_path(@transaction), notice: "Manual transaction added; balances unchanged."
  rescue ActiveRecord::RecordInvalid => e
    render :new, status: :unprocessable_entity
  end
  def update
    @transaction = transaction = current_user.transactions.find(params[:id])
    attrs = category_edit_params(transaction, transaction_params)
    attrs = attrs.except(:amount, :date, :account_id, :source_account_name, :iso_currency_code) unless transaction.source_manual? && !transaction.is_split? && !transaction.parent_id?
    if attrs.key?(:transfer) || attrs.key?(:card_payment)
      attrs[:classification_override] = true unless attrs[:classification_choice].present?
      attrs[:classification_origin] = "manual" unless attrs[:classification_choice].present?
    end
    transaction.update!(attrs)
    remember_merchant!(transaction)
    CashFlowClassifier.call(user: current_user)
    AutoCategorizer.call(user: current_user)
    redirect_to transaction_path(transaction.parent || transaction), notice: "Transaction updated."
  rescue ActiveRecord::RecordInvalid => e
    render :show, status: :unprocessable_entity
  end
  def bulk_update
    if params[:duplicate_review] == "1"
      selected = Array(params[:ids]).map(&:to_s).uniq
      group = DuplicateTransactionReview.new(current_user).groups.find { |entries| (selected - entries.map { |entry| entry.id.to_s }).empty? }
      if selected.empty? || !group || selected.size >= group.size
        return redirect_to duplicates_transactions_path, alert: "Select at least one copy and leave one transaction unselected."
      end

      current_user.transactions.roots.where(id: selected).update_all(duplicate: true, updated_at: Time.current)
      return redirect_to duplicates_transactions_path, notice: "Selected copies are excluded from reports. You can clear the Duplicate flag to restore them."
    end

    destination = transactions_path(params.fetch(:return_filters, ActionController::Parameters.new).permit(*TransactionSearch::FILTER_KEYS).to_h)
    selected = current_user.transactions.where(id: Array(params[:ids]).map(&:to_s).uniq)
    return redirect_to destination, alert: "Select at least one transaction to edit." unless selected.exists?

    attrs = params.fetch(:bulk, ActionController::Parameters.new).permit(:expense_type, :category_id, :tags, :hidden, :duplicate, :transfer, :card_payment).to_h.reject { |_, value| value.blank? }
    return redirect_to destination, alert: "Choose at least one change to apply." if attrs.empty?
    attrs["expense_type"] = nil if attrs["expense_type"] == "automatic"
    if attrs.key?("category_id")
      attrs.merge!("category_locked" => true, "category_origin" => "manual", "category_reason" => "Your bulk category edit", "suggested_category_id" => nil, "category_suggestion_reason" => nil)
    end
    if attrs["category_id"] == "uncategorized"
      attrs["category_id"] = nil
    elsif attrs["category_id"].present?
      Category.for_user(current_user).find(attrs["category_id"])
    end
    if attrs.key?("transfer") || attrs.key?("card_payment")
      attrs["classification_override"] = true
      attrs["classification_origin"] = "manual"
      attrs["classification_reason"] = "Your bulk cash-flow classification"
      attrs["matched_transaction_id"] = nil
      attrs["suggested_classification"] = nil
      attrs["suggestion_reason"] = nil
    end
    changed_count = 0
    Transaction.transaction do
      selected.each { |t| t.update!(attrs); changed_count += 1 }
    end
    CashFlowClassifier.call(user: current_user)
    AutoCategorizer.call(user: current_user)
    redirect_to destination, notice: "#{changed_count} #{'transaction'.pluralize(changed_count)} updated."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to destination || transactions_path, alert: "No changes were saved. #{e.record.errors.full_messages.to_sentence}"
  end
  def categorize
    CashFlowClassifier.call(user: current_user)
    result = AutoCategorizer.call(user: current_user)
    redirect_to transactions_path, notice: "#{result.categorized} transactions categorized, #{result.suggestions} need review, and #{result.uncategorized} remain uncategorized."
  end
  def classify
    result = CashFlowClassifier.call(user: current_user)
    redirect_to transactions_path, notice: "Automatic detection: #{result.automatic_transfers} transfers, #{result.automatic_card_payments} card-payment transactions excluded; #{result.suggestions} suggestions need review."
  end
  def split
    @transaction = current_user.transactions.roots.find(params[:id])
    @split_rows = params.require(:splits).values.map { |row| row.permit(:name, :amount, :category_id).to_h.symbolize_keys }
    @transaction.replace_splits!(@split_rows)
    redirect_to transaction_path(@transaction), notice: "Splits saved. Reports count only the split amounts."
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    @split_error = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message
    render :show, status: :unprocessable_entity
  end
  def unsplit
    transaction = current_user.transactions.roots.find(params[:id])
    Transaction.transaction { transaction.splits.destroy_all; transaction.update!(is_split: false, split_needs_review: false) }
    redirect_to transaction_path(transaction), notice: "Original transaction restored."
  end
  private
  def load_categories
    @categories = Category.for_user(current_user).includes(:parent).order(:name)
    @category_options = @categories.map { |c| [c.display_name, c.id] }.sort_by(&:first)
  end
  def category_edit_params(transaction, attrs)
    selected = attrs[:category_id].to_s
    changed = attrs.key?(:category_id) && selected != transaction.category_id.to_s
    keep = params.dig(:transaction, :lock_category)
    if changed || (keep == "1" && !transaction.category_locked?) || params.dig(:transaction, :remember_merchant) == "1"
      attrs.merge!(category_locked: true, category_origin: "manual", category_reason: "Your category choice", suggested_category_id: nil, category_suggestion_reason: nil)
    elsif keep == "0" && transaction.category_locked?
      attrs.merge!(category_id: nil, category_locked: false, category_origin: nil, category_reason: nil, suggested_category_id: nil, category_suggestion_reason: nil)
    end
    attrs
  end
  def remember_merchant!(transaction)
    return unless params.dig(:transaction, :remember_merchant) == "1" && transaction.category_id.present? && transaction.merchant_key.present?
    rule = current_user.transaction_rules.find_or_initialize_by(merchant_key: transaction.merchant_key)
    rule.update!(category: transaction.category, match_text: transaction.merchant_name.presence || transaction.name, kind: "regular")
  end
  def transaction_params
    attrs = params.require(:transaction).permit(:name, :date, :amount, :iso_currency_code, :source_account_name, :category_id, :notes, :tags, :hidden, :duplicate, :transfer, :card_payment, :classification_choice, :expense_type)
    Category.for_user(current_user).find(attrs[:category_id]) if attrs[:category_id].present?
    attrs
  end
end
