# frozen_string_literal: true

# Run only inside the disposable database created by bin/demo.
config = ActiveRecord::Base.connection_db_config.configuration_hash
unless Rails.env.development? && ENV["WORTH_DEMO"] == "1" &&
       config[:database] == "worth_demo" && config[:host].to_s.match?(%r{\A/tmp/worth-demo\.[A-Za-z0-9]+/socket\z})
  abort "Run bin/demo to load fictional data into a disposable local database."
end

User.transaction do
  demo = User.create!(email: "demo@example.com", password: "worth-demo-local")
  month = Date.current.beginning_of_month
  accounts = {
    checking: demo.accounts.create!(name: "Demo Checking", account_type: "depository",
      import_source_key: "demo-checking", iso_currency_code: "USD", current_balance: 3830),
    savings: demo.accounts.create!(name: "Demo Savings", account_type: "depository",
      import_source_key: "demo-savings", iso_currency_code: "USD", current_balance: 8200)
  }
  categories = %w[Paycheck Rent Internet Groceries Restaurants].to_h do |name|
    [name, Category.find_by!(name: name, system: true)]
  end

  [month.prev_month(2), month.prev_month, month].each_with_index do |start, index|
    [
      [0, "Example Payroll", -3200, "Paycheck"],
      [1, "Example Apartments", 1160, "Rent"],
      [3, "Example Internet", 55, "Internet"],
      [5, "Corner Grocery", 86 + index * 5, "Groceries"],
      [9, "Example Café", 26 + index, "Restaurants"],
      [15, "Corner Grocery", 103 + index, "Groceries"]
    ].each do |day, name, amount, category|
      demo.transactions.create!(account: accounts[:checking], category: categories.fetch(category),
        date: [start + day.days, Date.current].min, name: name, amount: amount,
        iso_currency_code: "USD", source: "manual")
    end

    amounts = { checking: [2820, 3310, 3830], savings: [7100, 7650, 8200] }
    accounts.each do |key, account|
      demo.balance_snapshots.create!(account: account, as_of_date: [start.end_of_month, Date.current].min,
        current_balance: amounts.fetch(key).fetch(index), iso_currency_code: "USD")
    end
  end

  demo.budgets.create!(category: categories.fetch("Groceries"), amount: 300, currency: "USD",
    starts_on: month.prev_month(2), rollover: true)
  demo.recurring_items.create!(name: "Example Internet", account: accounts[:checking], amount: 55,
    currency: "USD", direction: "expense", frequency: "monthly", next_on: month.next_month + 3.days,
    status: "active")
  demo.manual_assets.create!(name: "Example Bicycle", asset_type: "other", currency: "USD",
    value: 420, valued_on: Date.current)
end
