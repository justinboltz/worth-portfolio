require "test_helper"
require "csv"

class ExpenseBreakdownTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []
  setup do
    @user = User.create!(email: "expenses@example.test", password: "test-password")
    @other = User.create!(email: "expenses-other@example.test", password: "test-password")
    @bills = Category.create!(name: "Bills & Utilities", system: true)
    @rent = Category.create!(name: "Rent", system: true, parent: @bills)
    @utilities = Category.create!(name: "Electricity", system: true, parent: @bills)
    post sign_in_path, params: { email: @user.email, password: "test-password" }
  end

  def entry(**attributes)
    @user.transactions.create!({ name: "Household expense", amount: 50, date: Date.current, source: "manual", iso_currency_code: "USD", category: @rent }.merge(attributes))
  end

  def report
    FinancialReport.new(user: @user, from: Date.current.beginning_of_month, to: Date.current)
  end

  test "defaults distinguish variable utilities from fixed rent and leave unknown categories unclassified" do
    fixed = entry(amount: 1000)
    entry(amount: 120, category: @utilities)
    entry(amount: 30, category: nil)
    custom = @user.categories.create!(name: "Rent")
    entry(amount: 20, category: custom)
    entry(amount: -500, expense_type: "fixed")
    %i[hidden duplicate transfer card_payment pending split_needs_review].each { |flag| entry(amount: 999, flag => true) }
    entry(amount: 999, iso_currency_code: "CAD")
    assert_equal({ "fixed" => 1000, "variable" => 120, "unclassified" => 50 }, report.expense_types)
    assert TransactionSearch.new(user: @user, params: { expense_type: "fixed" }).call.all? { |transaction| transaction.amount.positive? }
    assert_equal report.spending, report.expense_types.values.sum
    assert_equal report.spending, report.expense_monthly.sum { |_, amounts| amounts.values.sum }
    assert_equal [fixed.id], TransactionSearch.new(user: @user, params: { expense_type: "fixed", reportable: "1", flow: "outflow", currency: "USD" }).call.pluck(:id)
  end

  test "category choices are per user inherited reversible and cannot edit private categories" do
    patch expense_type_category_path(@bills), params: { expense_type: "fixed" }
    assert_redirected_to categories_path
    assert_equal "fixed", ExpenseClassification.new(@user).for_category(@utilities.id)
    assert_equal "variable", ExpenseClassification.new(@other).for_category(@utilities.id)
    patch expense_type_category_path(@utilities), params: { expense_type: "unclassified" }
    assert_equal "unclassified", ExpenseClassification.new(@user).for_category(@utilities.id)
    patch expense_type_category_path(@utilities), params: { expense_type: "automatic" }
    assert_equal "fixed", ExpenseClassification.new(@user).for_category(@utilities.id)
    patch expense_type_category_path(@bills), params: { expense_type: "automatic" }
    assert_equal "variable", ExpenseClassification.new(@user).for_category(@utilities.id)
    patch expense_type_category_path(@rent), params: { expense_type: "bad-value" }
    assert_equal 0, @user.category_expense_types.count
    private_category = @other.categories.create!(name: "Private")
    patch expense_type_category_path(private_category), params: { expense_type: "fixed" }
    assert_response :not_found
    assert_equal "Rent", @rent.reload.name
  end

  test "split overrides and category inheritance match chart filters and CSV" do
    parent = entry(amount: 100, expense_type: "fixed")
    parent.replace_splits!([{ name: "Split A", amount: "40", category_id: @utilities.id }, { name: "Split B", amount: "60" }])
    child = parent.splits.order(:id).first
    child.update!(expense_type: "variable")
    assert_equal({ "fixed" => 60, "variable" => 40, "unclassified" => 0 }, report.expense_types)
    %w[fixed variable unclassified].each do |type|
      get transactions_path(format: :csv), params: { expense_type: type, flow: "outflow", reportable: "1" }
      assert_response :success
      rows = CSV.parse(response.body, headers: true)
      assert_equal report.expense_types[type], rows.sum { |row| row['Amount'].to_d }
      assert rows.all? { |row| row['ExpenseType'] == ExpenseClassification::LABELS[type] }
    end
    parent.update!(expense_type: nil)
    child.update!(expense_type: nil)
    assert_equal({ "fixed" => 0, "variable" => 40, "unclassified" => 60 }, report.expense_types)
    parent.update!(hidden: true)
    assert_equal 0, report.spending
  end

  test "chart supports monthly navigation percentages and matching drilldowns" do
    entry(amount: 1000)
    entry(amount: 200, category: @utilities)
    entry(amount: 50, category: nil)
    entry(amount: 800, date: Date.current.prev_month)
    get trends_path, params: { spending_view: "cost_type" }
    assert_response :success
    assert_select 'h2', text: 'Fixed & variable expenses'
    assert_select '.spending-legend-row', count: 3
    assert_select '.spending-legend-row', text: /Fixed.*1,000.00.*80.0%/
    assert_select '.expense-month', count: 1
    link = css_select('.spending-legend-row a').first['href']
    get link
    assert_response :success
    assert_select 'tbody tr', count: 1
    get trends_path, params: { spending_view: 'cost_type', month: Date.current.prev_month.strftime('%Y-%m'), from: Date.current.iso8601, to: Date.current.iso8601 }
    assert_select '.metric', text: /Spending.*800.00/
    get trends_path, params: { spending_view: 'cost_type', month: Date.current.prev_month.strftime('%Y-%m'), q: 'Household' }
    assert_select '.filter-chip[href*="month="]'
    assert_select '.transaction-search input[name=month]', count: 0
    get trends_path, params: { spending_view: 'cost_type', month: '2026-99' }
    assert_redirected_to trends_path
  end

  test "transaction override edits and bulk reset are validated" do
    transaction = entry
    patch transaction_path(transaction), params: { transaction: { expense_type: "variable" } }
    assert_equal 'variable', transaction.reload.expense_type
    patch bulk_update_transactions_path, params: { ids: [transaction.id], bulk: { expense_type: 'automatic' } }
    assert_nil transaction.reload.expense_type
    patch bulk_update_transactions_path, params: { ids: [transaction.id], bulk: { expense_type: 'bad-value', tags: 'must not save' } }
    assert_equal '', transaction.reload.tags
    get transactions_path, params: { expense_type: 'bad-value' }
    assert_response :unprocessable_entity
    get edit_category_path(@rent)
    assert_response :success
    assert_select 'select[name=expense_type]'
  end
end
