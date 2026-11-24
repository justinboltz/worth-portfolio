class BudgetsController < ApplicationController
  before_action :require_authentication
  def index
    load_budget_data
  end
  def create
    @draft = current_user.budgets.new(budget_params)
    if @draft.save
      redirect_to budgets_path(month: @draft.starts_on.strftime('%Y-%m')), notice: "Monthly budget created."
    else
      load_budget_data
      render :index, status: :unprocessable_entity
    end
  end
  def update
    @editing_budget = current_user.budgets.find(params[:id])
    attrs = budget_params
    if attrs[:starts_on].present? && Date.parse(attrs[:starts_on]) != @editing_budget.starts_on
      @editing_budget.errors.add(:starts_on, "cannot change; create a new budget instead")
    elsif @editing_budget.update(attrs)
      return redirect_to budgets_path(month: params[:month].presence), notice: "Recurring budget updated. Rollover uses this amount from its start month."
    end
    load_budget_data
    render :index, status: :unprocessable_entity
  rescue Date::Error
    @editing_budget.errors.add(:starts_on, "must be a valid date")
    load_budget_data
    render :index, status: :unprocessable_entity
  end
  def destroy
    current_user.budgets.find(params[:id]).destroy!
    redirect_to budgets_path(month: params[:month].presence), notice: "Budget removed."
  end
  private
  def load_budget_data
    @month = params[:month].present? ? Date.iso8601("#{params[:month]}-01") : Date.current.beginning_of_month
    @draft ||= current_user.budgets.new(starts_on: @month, currency: "USD")
    @budgets = current_user.budgets.includes(:category).where(starts_on: ..@month).order(:id)
    @categories = Category.for_user(current_user).includes(:parent).sort_by(&:display_name)
    @budgets = @budgets.where(currency: params[:currency]) if params[:currency].present?
    @budgets = @budgets.select { |budget| budget.category.display_name.downcase.include?(params[:q].strip.downcase) } if params[:q].present?
    @budgets = @budgets.select { |budget| budget.available(@month) - budget.spending(@month) < 0 } if params[:status] == "over"
    @budgets = @budgets.select { |budget| budget.available(@month) - budget.spending(@month) >= 0 } if params[:status] == "within"
    @budget_totals = @budgets.to_h { |budget| [budget.id, [budget.spending(@month), budget.available(@month)]] }
    @budgets = @budgets.map { |budget| @editing_budget&.id == budget.id ? @editing_budget : budget }
  rescue Date::Error
    redirect_to budgets_path, alert: "Choose a valid month"
  end
  def budget_params
    params.require(:budget).permit(:category_id, :amount, :currency, :starts_on, :rollover)
  end
end
