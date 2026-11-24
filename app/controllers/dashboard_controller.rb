class DashboardController < ApplicationController
  before_action :require_authentication

  def show
    @month = Date.current.beginning_of_month
    monthly = current_user.transactions.reportable.where(date: @month..Date.current, pending: false, iso_currency_code: "USD")
    @previous_spending = current_user.transactions.reportable.where(date: @month.prev_month..@month.prev_month.end_of_month, iso_currency_code: "USD").where("amount > 0").sum(:amount)
    @spending = monthly.where("amount > 0").sum(:amount)
    @income = -monthly.where("amount < 0").sum(:amount)
    @category_spending = monthly.where("amount > 0").includes(:category).group_by { |transaction| transaction.category&.name || "Uncategorized" }.map { |name, transactions| [name, transactions.sum(&:amount)] }.sort_by { |_, amount| -amount }
    @currency_groups = @sidebar_accounts.reject(&:net_worth_excluded?).group_by { |account| account.iso_currency_code.presence || "Unknown" }
    @net_worth = @currency_groups.transform_values { |accounts| accounts.sum { |account| helpers.signed_balance(account) } }
    @missing_balances = @sidebar_accounts.count { |account| !account.net_worth_excluded? && account.current_balance.nil? }
    @sidebar_assets.each { |asset| @net_worth[asset.currency] = @net_worth.fetch(asset.currency, 0) + asset.value }
    @plaid_items = current_user.plaid_items.includes(:institution, :accounts).order(created_at: :desc)
    @recent_transactions = current_user.transactions.tracked.roots.includes(:account, :category).order(date: :desc, id: :desc).limit(8)
  end
end
