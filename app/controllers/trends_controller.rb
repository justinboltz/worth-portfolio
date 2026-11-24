class TrendsController < ApplicationController
  before_action :require_authentication
  def show
    @spending_view = params[:spending_view] == "cost_type" ? "cost_type" : "category"
    if params[:month].present?
      raise ArgumentError, "Choose a valid month" unless params[:month].match?(/\A\d{4}-\d{2}\z/)
      @from = Date.iso8601("#{params[:month]}-01")
      @to = [@from.end_of_month, Date.current].min
    else
      @from = params[:from].present? ? Date.iso8601(params[:from]) : Date.current.beginning_of_month - (@spending_view == "category" ? 5.months : 0.months)
      @to = params[:to].present? ? Date.iso8601(params[:to]) : Date.current
    end
    raise ArgumentError, "Choose a range of up to 20 years" if @from > @to || (@to - @from) > 7305
    @currency = %w[USD CAD EUR GBP].include?(params[:currency]) ? params[:currency] : "USD"
    @categories = Category.for_user(current_user).includes(:parent).sort_by(&:display_name)
    @category_options = @categories.map { |category| [category.display_name, category.id] }
    @source_accounts = current_user.transactions.tracked.where.not(source_account_name: [nil, ""]).distinct.order(:source_account_name).pluck(:source_account_name)
    search = TransactionSearch.new(user: current_user, params: params.except(:flag).merge(currency: @currency, from: @from.iso8601, to: @to.iso8601))
    scope = search.call
    @filter_errors = search.errors
    @report = FinancialReport.new(user: current_user, from: @from, to: @to, currency: @currency, scope: scope)
    @history = FinancialReport.net_worth_history(current_user, currency: @currency, from: @from, to: @to)
    render :show, status: @filter_errors.any? ? :unprocessable_entity : :ok
  rescue Date::Error, ArgumentError => e
    redirect_to trends_path, alert: e.message
  end
end
