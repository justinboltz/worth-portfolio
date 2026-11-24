class FinancialReport
  COLORS = %w[#008d82 #69b8a5 #efb85a #779bc4 #b38db8 #e08070 #8caa69 #66777d].freeze
  attr_reader :transactions, :spending, :income, :categories, :monthly, :expense_types, :expense_monthly
  def initialize(user:, from:, to:, currency: "USD", scope: nil)
    @transactions = (scope || user.transactions).reportable.where(date: from..to, iso_currency_code: currency).includes(:parent, category: :parent)
    @spending = transactions.where("transactions.amount > 0").sum(:amount)
    @income = -transactions.where("transactions.amount < 0").sum(:amount)
    @categories = transactions.where("transactions.amount > 0").to_a.group_by { |t| t.category&.root_category }.map { |category, rows| [category, rows.sum(&:amount)] }.sort_by { |_, amount| -amount }
    @monthly = transactions.to_a.group_by { |t| t.date.beginning_of_month }.sort.map { |month, rows| [month, rows.select { |t| t.amount.positive? }.sum(&:amount), -rows.select { |t| t.amount.negative? }.sum(&:amount)] }
    classifier = ExpenseClassification.new(user)
    @expense_types = ExpenseClassification::LABELS.keys.index_with { 0.to_d }
    @expense_monthly = {}
    transactions.each do |transaction|
      next unless transaction.amount.positive?
      type = classifier.for_transaction(transaction)
      @expense_types[type] += transaction.amount
      month = transaction.date.beginning_of_month
      @expense_monthly[month] ||= ExpenseClassification::LABELS.keys.index_with { 0.to_d }
      @expense_monthly[month][type] += transaction.amount
    end
    @expense_monthly = @expense_monthly.sort
  end
  def self.net_worth_history(user, currency:, from:, to:)
    snapshots = user.balance_snapshots.where(account_id: user.accounts.in_net_worth.select(:id)).includes(:account).where(iso_currency_code: currency, as_of_date: ..to).order(:as_of_date).to_a
    assets = user.manual_assets.where(currency: currency).includes(:asset_valuations).to_a
    dates = (snapshots.map(&:as_of_date) + assets.flat_map { |a| a.asset_valuations.map(&:valued_on) }).uniq.select { |date| (from..to).cover?(date) }.sort
    total_accounts = user.accounts.in_net_worth.where(iso_currency_code: currency).count
    dates.map do |date|
      known = snapshots.select { |s| s.as_of_date <= date && !s.current_balance.nil? }.group_by(&:account_id).values.map(&:last)
      value = known.sum { |s| %w[credit loan].include?(s.account.account_type) ? -s.current_balance : s.current_balance }
      known_assets = assets.filter_map { |a| a.asset_valuations.select { |v| v.valued_on <= date }.max_by(&:valued_on) }
      value += known_assets.sum(&:value)
      [date, value, known.size, total_accounts, known_assets.size, assets.size]
    end
  end
end
