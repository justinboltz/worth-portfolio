require "test_helper"
require "csv"
class MintWorkflowsTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []
  setup do
    @user = User.create!(email: "mint@example.com", password: "test-password")
    @food = @user.categories.create!(name: "Food")
    @groceries = @user.categories.create!(name: "Groceries", parent: @food)
    post sign_in_path, params: { email: @user.email, password: "test-password" }
  end
  def transaction(**attrs)
    @user.transactions.create!({ source: "manual", amount: 20, date: Date.current, name: "Market", category: @groceries, iso_currency_code: "USD" }.merge(attrs))
  end
  test "all screens render and manual transactions never create accounts or snapshots" do
    assert_no_difference ["Account.count", "BalanceSnapshot.count", "PlaidItem.count"] do
      post transactions_path, params: { transaction: { name: "Lunch", amount: "12.50", date: Date.current, iso_currency_code: "USD", category_id: @food.id, tags: "work, work, lunch" } }
    end
    t = @user.transactions.last
    assert_equal "work, lunch", t.tags
    [root_path, transactions_path, transaction_path(t), new_transaction_path, new_import_path, categories_path, transaction_rules_path, budgets_path, trends_path].each do |path|
      get path
      assert_response :success, path
    end
  end
  test "staged imports map arbitrary headers and categories, preserve account names and reimport safely" do
    csv = "When,Who,Value,Group,Bank\n2026-09-01,Market,25.00,Old Food,Old Checking\n"
    batch = @user.import_batches.create!(csv_text: csv)
    get import_path(batch)
    assert_response :success
    assert_select '.flash-alert', text: /required date/
    mapping = { headers: { date: "When", description: "Who", amount: "Value", category: "Group", account: "Bank" }, categories: { "Old Food" => @groceries.id.to_s }, currency: "USD", reverse_sign: "0" }
    patch import_path(batch), params: mapping
    follow_redirect!
    assert_response :success
    assert_select 'td', text: /Market/
    assert_no_difference ["Account.count", "BalanceSnapshot.count", "PlaidItem.count", "Category.count"] do
      patch import_path(batch), params: mapping.merge(commit_import: "Confirm import", profile_name: "My bank")
    end
    assert_redirected_to transactions_path
    t = @user.transactions.last
    assert_equal "Old Checking", t.source_account_name
    assert_nil t.account_id
    assert_equal @groceries, t.category
    assert_equal 1, @user.import_profiles.count
    assert_equal 1, @user.transactions.count
    again = @user.import_batches.create!(csv_text: csv, settings: @user.import_profiles.first.settings)
    assert_equal 0, Imports::CsvPreview.new(again).commit!
    assert_raises(ArgumentError) { Imports::CsvPreview.new(again).commit! }
  end
  test "duplicates require review and included duplicates are excluded from reports" do
    transaction(date: Date.new(2026, 9, 1), amount: 25)
    batch = @user.import_batches.create!(csv_text: "Date,Description,Amount\n2026-09-01,Other description,25\n")
    preview = Imports::CsvPreview.new(batch)
    assert_equal 1, preview.rows.first[:candidates].size
    assert_equal 1, preview.commit!(include_duplicates: [2])
    assert @user.transactions.last.duplicate?
    assert_equal 25.to_d, @user.transactions.reportable.sum(:amount)
  end
  test "bad rows prevent partial imports and signed Mint credits work" do
    bad = @user.import_batches.create!(csv_text: "Date,Description,Amount\n2026-09-01,Valid,2\nbad,Invalid,nope\n")
    assert_raises(ArgumentError) { Imports::CsvPreview.new(bad).commit! }
    assert_equal 0, @user.transactions.count
    good = @user.import_batches.create!(csv_text: "Date,Description,Amount,Transaction Type\n09/01/2026,Pay,100,credit\n")
    assert_equal(-100.to_d, Imports::CsvPreview.new(good).rows.first[:attrs][:amount])
  end
  test "consistent flags, parent categories, splits and rollover budgets" do
    month = Date.current.beginning_of_month
    t = transaction(amount: 100)
    transaction(amount: 500, transfer: true)
    transaction(amount: 500, card_payment: true)
    transaction(amount: 500, duplicate: true)
    transaction(amount: 500, hidden: true)
    transaction(amount: 500, pending: true)
    transaction(amount: -1000, category: nil)
    t.replace_splits!([{ name: "Produce", amount: "60", category_id: @groceries.id }, { name: "Dining", amount: "40", category_id: @food.id }])
    report = FinancialReport.new(user: @user, from: month, to: month.end_of_month)
    assert_equal 100.to_d, report.spending
    assert_equal 1000.to_d, report.income
    assert_equal [[@food, 100.to_d]], report.categories
    budget = @user.budgets.create!(category: @food, amount: 200, starts_on: month.prev_month, rollover: true)
    transaction(date: month.prev_month, amount: 50)
    assert_equal 350.to_d, budget.available(month)
    assert_equal 100.to_d, budget.spending(month)
    get budgets_path
    assert_response :success
    assert_select 'h2', text: @food.name
    get transactions_path(category_id: @food.id, reportable: "1", from: month, to: month.end_of_month)
    assert_response :success
    assert_select 'a', text: 'Produce'
    t.update!(hidden: true)
    assert_equal 0, budget.spending(month)
    assert_raises(ArgumentError) { t.replace_splits!([{ name: "Bad", amount: "1" }, { name: "Bad", amount: "2" }]) }
    assert_equal 2, t.splits.count
    get transactions_path(format: :csv)
    csv = CSV.parse(response.body, headers: true)
    assert_equal 100.to_d, csv.select { |r| r['ParentID'] == t.id.to_s }.sum { |r| BigDecimal(r['Amount']) }
    assert csv.select { |r| r['ParentID'] == t.id.to_s }.all? { |r| r['Hidden'] == 'true' }
    assert_equal @user.transactions.where(is_split: false).count, csv.size
  end
  test "rules apply to new transactions and merges update only this user's usage" do
    post transaction_rules_path, params: { transaction_rule: { match_text: "market", category_id: @food.id, kind: "transfer", tags: "rule" } }
    t = transaction
    assert t.transfer?
    assert_equal @food, t.category
    assert_equal 'rule', t.tags
    @user.transaction_rules.destroy_all
    target = @user.categories.create!(name: "Household")
    post merge_category_path(@food), params: { target_id: target.id }
    assert_equal target, t.reload.category
    assert_not @user.categories.exists?(@food.id)
    assert_not @user.categories.exists?(@groceries.id)
    assert_equal 0, @user.transactions.reportable.count
  end
  test "foreign records cannot be edited or assigned" do
    other = User.create!(email: "other-mint@example.com", password: "test-password")
    category = other.categories.create!(name: "Private")
    t = transaction
    patch transaction_path(t), params: { transaction: { category_id: category.id } }
    assert_response :not_found
    foreign = other.transactions.create!(source: "manual", name: "Private", date: Date.current, amount: 1)
    get transaction_path(foreign)
    assert_response :not_found
    post budgets_path, params: { budget: { category_id: category.id, amount: 100, starts_on: Date.current, currency: "USD" } }
    assert_equal 0, @user.budgets.count
    post transaction_rules_path, params: { transaction_rule: { match_text: "a", category_id: category.id, kind: "regular" } }
    assert_equal 0, @user.transaction_rules.count
  end
  test "CSV history cannot fabricate net worth history" do
    transaction(date: 2.years.ago.to_date, amount: 500)
    assert_empty FinancialReport.net_worth_history(@user, currency: 'USD', from: 3.years.ago.to_date, to: Date.current)
    @user.manual_assets.create!(name: "Home", asset_type: "property", value: 300000, currency: "USD", valued_on: Date.current)
    history = FinancialReport.net_worth_history(@user, currency: 'USD', from: 3.years.ago.to_date, to: Date.current)
    assert_equal 1, history.size
    assert_equal Date.current, history.first[0]
    assert_equal 300000.to_d, history.first[1]
  end
  test "Worth branding and the Budget model coexist" do
    assert Worth::Application < Rails::Application
    assert Budget < ApplicationRecord
    get root_path
    assert_select 'title', text: 'Overview · Worth'
    assert_select '.wordmark', text: 'worth'
    get pwa_manifest_path
    assert_equal 'Worth', JSON.parse(response.body)['name']
  end
  test "within file duplicates need explicit review" do
    batch = @user.import_batches.create!(csv_text: "Date,Description,Amount\n2026-09-01,Coffee,5\n2026-09-01,Coffee,5\n")
    preview = Imports::CsvPreview.new(batch)
    assert preview.rows.last[:file_duplicate]
    assert_equal 1, preview.commit!
    assert_equal 1, @user.transactions.count
  end
  test "bulk updates clear flags and categories without crossing user ownership" do
    t = transaction(hidden: true)
    patch bulk_update_transactions_path, params: { ids: [t.id], bulk: { hidden: '0', category_id: 'uncategorized', tags: 'reviewed' } }
    assert_not t.reload.hidden?
    assert_nil t.category_id
    assert_equal 'reviewed', t.tags
  end
  def local_bank
    institution = Institution.create!(name: 'Test bank', plaid_institution_id: 'fake-institution')
    item = @user.plaid_items.create!(institution: institution, plaid_item_id: 'fake-item', access_token: 'fake-test-token')
    account = @user.accounts.create!(plaid_item: item, plaid_account_id: 'fake-account', name: 'Test checking', account_type: 'depository', iso_currency_code: 'USD', current_balance: 100)
    [item, account]
  end
  test "cached account sync records real balance observations with partial historical coverage" do
    item, account = local_bank
    Plaid::UpsertAccounts.call(user: @user, plaid_item: item, accounts: [{ 'account_id' => account.plaid_account_id, 'name' => account.name, 'type' => 'depository', 'balances' => { 'current' => 120, 'iso_currency_code' => 'USD' } }])
    assert_equal 1, @user.balance_snapshots.count
    assert_equal 120.to_d, @user.balance_snapshots.first.current_balance
    assert_equal Date.current, @user.balance_snapshots.first.as_of_date
    @user.accounts.create!(plaid_item: item, plaid_account_id: 'unobserved', name: 'No history', account_type: 'depository', iso_currency_code: 'USD')
    history = FinancialReport.net_worth_history(@user, currency: 'USD', from: Date.yesterday, to: Date.current)
    assert_equal [Date.current, 120.to_d, 1, 2, 0, 0], history.first
  end
  test "bank amount changes preserve splits and require reconciliation without a live call" do
    item, account = local_bank
    t = transaction(source: 'plaid', account: account, plaid_item: item, plaid_transaction_id: 'fake-txn', amount: 100)
    t.replace_splits!([{ name: 'Produce', amount: '60', category_id: @groceries.id }, { name: 'Dining', amount: '40', category_id: @food.id }])
    Plaid::UpsertTransactions.upsert_one(user: @user, plaid_item: item, payload: { 'transaction_id' => 'fake-txn', 'account_id' => account.plaid_account_id, 'name' => 'Market', 'amount' => 110, 'date' => Date.current.to_s, 'iso_currency_code' => 'USD' })
    assert t.reload.split_needs_review?
    assert_equal 2, t.splits.count
    assert_equal 0, @user.transactions.reportable.sum(:amount)
    get transaction_path(t)
    assert_select '.flash-alert', text: /split edits are preserved/
    t.replace_splits!([{ name: 'Produce', amount: '70', category_id: @groceries.id }, { name: 'Dining', amount: '40', category_id: @food.id }])
    assert_not t.reload.split_needs_review?
    assert_equal 110.to_d, @user.transactions.reportable.sum(:amount)
  end

  test "multipart CSV upload stages data before confirmation" do
    Tempfile.create(['worth-import', '.csv']) do |file|
      file.write("Date,Description,Amount,Account\n2026-09-01,Sample,12,Retired account\n")
      file.flush
      upload = Rack::Test::UploadedFile.new(file.path, 'text/csv')
      assert_difference '@user.import_batches.count', 1 do
        assert_no_difference '@user.transactions.count' do
          post imports_path, params: { file: upload }
        end
      end
      assert_redirected_to import_path(@user.import_batches.last)
      follow_redirect!
      assert_response :success
      assert_select 'td', text: /Retired account/
    end
  end

end
