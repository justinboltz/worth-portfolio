module ApplicationHelper
  def page_title
    names = {
      "dashboard" => "Overview", "transactions" => "Transactions", "budgets" => "Monthly budgets",
      "trends" => "Trends", "categories" => "Categories", "transaction_rules" => "Transaction rules", "recurring_items" => "Bills and subscriptions",
      "manual_assets" => "My assets", "imports" => "Import transactions", "passwords" => "Change password",
      "bank_connections" => "Connect a bank", "sessions" => "Sign in", "users" => "Create an account"
    }
    title = content_for(:title).presence || names[controller_name] || "Your finances"
    "#{title} · Worth"
  end

  def money(amount, currency = "USD")
    return "Unavailable" if amount.nil?
    number_to_currency(amount, unit: currency == "USD" ? "$" : "#{currency} ")
  end

  def spending_gradient(categories, total, colors: FinancialReport::COLORS)
    position = 0
    segments = categories.each_with_index.map do |(_, amount), i|
      start = position
      position += (amount / total * 100).to_f
      "#{colors[i % colors.size]} #{start.round(3)}% #{position.round(3)}%"
    end
    "conic-gradient(#{segments.join(', ')})"
  end

  def signed_balance(account)
    %w[credit loan].include?(account.account_type) ? -account.current_balance.to_d : account.current_balance.to_d
  end

  def transaction_filter_params
    params.permit(*TransactionSearch::FILTER_KEYS).to_h.reject { |_, value| value.blank? }
  end

  def transaction_filter_labels
    transaction_filter_params.filter_map do |key, value|
      next if %w[sort direction per_page].include?(key)
      label = case key
      when "q" then "Search: #{value}"
      when "account_id" then "Account: #{@sidebar_accounts.find { |account| account.id.to_s == value }&.name || 'Unavailable'}"
      when "category_id" then "Category: #{value == 'uncategorized' ? 'Uncategorized' : @category_options.find { |_, id| id.to_s == value }&.first || 'Unavailable'}"
      when "source_account_name" then "Imported account: #{value}"
      when "source" then "Source: #{ { 'plaid' => 'Bank sync', 'import' => 'File import', 'manual' => 'Manual entry' }[value] || value }"
      when "reportable" then "Included in reports"
      when "min_amount" then "Minimum: #{value}"
      when "max_amount" then "Maximum: #{value}"
      else "#{key.humanize}: #{value.humanize}"
      end
      [key, label]
    end
  end
end
