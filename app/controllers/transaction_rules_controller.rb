class TransactionRulesController < ApplicationController
  before_action :require_authentication
  before_action :load_rule_data, only: %i[index edit create update]
  def edit
    @draft = current_user.transaction_rules.find(params[:id])
  end
  def index
    @draft = current_user.transaction_rules.new
    if params[:q].present?
      query = params[:q].strip.downcase
      @rules = @rules.select { |rule| [rule.match_text, rule.category&.display_name, rule.account&.name, rule.source_account_name, rule.tags].compact.any? { |value| value.downcase.include?(query) } }
    end
    @rules = @rules.select { |rule| rule.kind == params[:kind] } if params[:kind].present?
  end
  def create
    @draft = current_user.transaction_rules.new(rule_params)
    if params[:preview] == "1"
      return preview_rule
    end
    @draft.save!
    apply_rule(@draft) if params[:apply_existing] == "1"
    refresh_categories
    redirect_to transaction_rules_path, notice: "Rule saved. New imports, bank and manual transactions use its conditions."
  rescue ActiveRecord::RecordInvalid => e
    @draft = e.record
    render :index, status: :unprocessable_entity
  end
  def update
    rule = current_user.transaction_rules.find(params[:id])
    rule.assign_attributes(rule_params)
    if params[:preview] == "1"
      @draft = rule
      return preview_rule
    end
    rule.effective_from = Time.current
    rule.save!
    apply_rule(rule) if params[:apply_existing] == "1"
    refresh_categories
    redirect_to transaction_rules_path, notice: "Rule updated. Existing edits stay unchanged unless you apply the rule to history."
  rescue ActiveRecord::RecordInvalid => e
    @draft = e.record
    render :index, status: :unprocessable_entity
  end
  def destroy
    current_user.transaction_rules.find(params[:id]).destroy!
    redirect_to transaction_rules_path, notice: "Rule removed. Existing edits are preserved."
  end
  private
  def load_rule_data
    @rules = current_user.transaction_rules.includes(:category, :account).order(:id)
    @categories = Category.for_user(current_user).includes(:parent).sort_by(&:display_name)
    @accounts = current_user.accounts.order(:name, :id)
    @source_accounts = current_user.transactions.tracked.where.not(source_account_name: [nil, ""]).distinct.order(:source_account_name).pluck(:source_account_name)
  end
  def rule_params
    params.require(:transaction_rule).permit(:match_text, :description_operator, :account_id, :source_account_name, :category_id, :kind, :tags)
  end
  def preview_rule
    unless @draft.valid?
      return render :index, status: :unprocessable_entity
    end
    matches = current_user.transactions.roots.includes(:account, :category).order(date: :desc, id: :desc).select { |t| @draft.matches?(t) }
    @match_count = matches.size
    @protected_category_count = matches.count { |t| t.category_locked? && %w[manual import existing split].include?(t.category_origin) }
    @preview_transactions = matches.first(10)
    render :index
  end
  def apply_rule(rule)
    Transaction.transaction do
      current_user.transactions.roots.find_each do |t|
        rule.apply_to(t)
        t.save! if t.changed?
      end
    end
  end
  def refresh_categories
    CashFlowClassifier.call(user: current_user)
    AutoCategorizer.call(user: current_user)
  end
end
