class RecurringItemsController < ApplicationController
  before_action :require_authentication
  before_action :load_accounts, only: %i[new create edit update]
  before_action :find_item, only: %i[edit update destroy]

  def index
    @items = current_user.recurring_items.includes(:account).order(:name).to_a
    @from, @to = Date.current, Date.current + 29
    @upcoming = @items.flat_map { |item| item.occurrences(from: @from, to: @to).map { |date| [date, item] } }.sort_by { |date, item| [date, item.name] }
    @totals = @upcoming.group_by { |_, item| [item.direction, item.currency] }.transform_values { |rows| rows.sum { |_, item| item.amount } }
    detector = RecurringDetector.new(current_user)
    suggestions = detector.suggestions
    @suggestion_pages = [(suggestions.size / 8.0).ceil, 1].max
    @suggestion_page = [[params[:suggestion_page].to_i, 1].max, @suggestion_pages].min
    @suggestions = suggestions.slice((@suggestion_page - 1) * 8, 8) || []
    @suggestion_count = suggestions.size
    @histories = @items.to_h { |item| [item.id, detector.history_for(item.detection_key)] }
    @dismissals = current_user.recurring_dismissals.order(:name)
  end

  def new
    build_item
  end

  def create
    build_item
    @item.assign_attributes(item_params)
    if @item.save
      redirect_to recurring_items_path, notice: "Recurring item added. Your recorded transactions and balances are unchanged."
    else
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_to recurring_items_path, alert: "This recurring pattern is already tracked."
  end

  def edit
    @history = @item.linked_history
  end

  def update
    if @item.update(item_params)
      redirect_to recurring_items_path, notice: @item.status == "paused" ? "Tracking paused. This item is excluded from the outlook." : "Recurring item updated."
    else
      @history = @item.linked_history
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    RecurringItem.transaction do
      current_user.recurring_dismissals.find_or_create_by!(detection_key: @item.detection_key) { |dismissal| dismissal.name = @item.name } if @item.detection_key
      @item.destroy!
    end
    redirect_to recurring_items_path, notice: "Tracking stopped. Your recorded transactions are unchanged."
  end

  def dismiss
    transaction = current_user.transactions.roots.find(params[:transaction_id])
    key = RecurringDetector.key(transaction)
    return redirect_to recurring_items_path, alert: "This transaction has no distinct merchant pattern." unless key
    current_user.recurring_dismissals.find_or_create_by!(detection_key: key) { |dismissal| dismissal.name = transaction.name }
    redirect_to recurring_items_path, notice: "Suggestion dismissed. You can restore it below."
  end

  def restore_suggestion
    current_user.recurring_dismissals.find(params[:id]).destroy!
    redirect_to recurring_items_path, notice: "Suggestion restored. It will appear if the recent history still matches a recurring pattern."
  end

  private

  def load_accounts
    @accounts = current_user.accounts.order(:name)
  end

  def find_item
    @item = current_user.recurring_items.find(params[:id])
  end

  def build_item
    @item = current_user.recurring_items.new(next_on: Date.current, currency: "USD", frequency: "monthly", direction: "expense")
    return unless params[:transaction_id].present?
    @source_transaction = current_user.transactions.roots.find(params[:transaction_id])
    frequency = RecurringItem::FREQUENCIES.key?(params[:frequency]) ? params[:frequency] : "monthly"
    @item.assign_attributes(name: @source_transaction.merchant_name.presence || @source_transaction.name, amount: @source_transaction.amount.abs,
      currency: @source_transaction.iso_currency_code, direction: @source_transaction.amount.negative? ? "income" : "expense",
      frequency: frequency, next_on: @source_transaction.date, month_end: @source_transaction.date == @source_transaction.date.end_of_month, account: @source_transaction.account,
      source_account_name: @source_transaction.source_account_name, merchant_key: @source_transaction.merchant_key, detection_key: RecurringDetector.key(@source_transaction))
    @item.next_on = @item.next_occurrence([Date.current, @source_transaction.date + 1].max)
  end

  def item_params
    attrs = params.require(:recurring_item).permit(:name, :amount, :currency, :direction, :frequency, :next_on, :month_end, :account_id, :status, :notes)
    @item.merchant_key.present? ? attrs.except(:currency, :direction, :account_id) : attrs
  end
end
