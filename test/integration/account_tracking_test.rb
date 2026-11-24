require "test_helper"
require "csv"

class AccountTrackingTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []
  setup do
    @user = User.create!(email: "tracking@example.test", password: "test-password")
    bank = Institution.create!(name: "Multiple Cards Bank", plaid_institution_id: "tracking-bank")
    @item = @user.plaid_items.create!(institution: bank, plaid_item_id: "tracking-item", access_token: "fake-test-token")
    @first = @user.accounts.create!(plaid_item: @item, plaid_account_id: 'card-a', name: 'Daily card', account_type: 'credit', mask: '1234', current_balance: 100, iso_currency_code: 'USD')
    @second = @user.accounts.create!(plaid_item: @item, plaid_account_id: 'card-b', name: 'Business card', account_type: 'credit', mask: '5678', current_balance: 200, iso_currency_code: 'USD')
    @category = @user.categories.create!(name: "Household")
    [@first, @second].each do |account|
      @user.transactions.create!(account: account, plaid_item: @item, name: account.name, amount: account.current_balance, date: Date.current, source: 'plaid', iso_currency_code: 'USD', category: @category, expense_type: 'fixed')
      @user.balance_snapshots.create!(account: account, as_of_date: Date.current, current_balance: account.current_balance, iso_currency_code: 'USD')
    end
    post sign_in_path, params: { email: @user.email, password: 'test-password' }
  end

  test "choosing sub accounts changes balances reports exports and budgets while preserving history" do
    budget = @user.budgets.create!(category: @category, amount: 500, currency: 'USD', starts_on: Date.current.beginning_of_month)
    assert @first.tracked?
    assert_no_difference ['Transaction.count', 'BalanceSnapshot.count', 'Account.count'] do
      patch tracking_plaid_item_path(@item), params: { account_ids: ['', @first.id] }
    end
    assert_redirected_to root_path
    assert_not @second.reload.tracked?
    assert_equal 100, FinancialReport.new(user: @user, from: Date.current, to: Date.current).spending
    history = FinancialReport.net_worth_history(@user, currency: 'USD', from: Date.current, to: Date.current)
    assert_equal [-100, 1, 1], history.first[1..3]
    assert_equal 100, budget.spending(Date.current.beginning_of_month)
    get transactions_path(format: :csv)
    assert_equal ['Daily card'], CSV.parse(response.body, headers: true).map { |row| row['Description'] }
    get root_path
    assert_response :success
    assert_select '.recent-list', text: /Daily card/
    assert_select '.recent-list', text: /Business card/, count: 0
    assert_select "input[id='track_account_#{@first.id}'][checked]"
    assert_select "input[id='track_account_#{@second.id}']:not([checked])"
    patch tracking_plaid_item_path(@item), params: { account_ids: [@first.id, @second.id] }
    assert_equal 300, FinancialReport.new(user: @user, from: Date.current, to: Date.current).spending
  end

  test "none may be tracked and split expenses and recurring outlook are excluded" do
    parent = @user.transactions.find_by(account: @second)
    parent.replace_splits!([{ name: 'Split A', amount: '125' }, { name: 'Split B', amount: '75' }])
    recurring = @user.recurring_items.create!(account: @second, name: 'Card plan', amount: 12, currency: 'USD', frequency: 'monthly', direction: 'expense', next_on: Date.current, status: 'active')
    patch tracking_plaid_item_path(@item), params: { account_ids: [''] }
    assert_equal 0, @user.transactions.reportable.count
    assert_equal 0, TransactionSearch.new(user: @user, params: {}).call.count
    assert_empty recurring.reload.occurrences(from: Date.current, to: Date.current + 30)
    get recurring_items_path
    assert_select '.recurring-tile', text: /Account excluded from tracking/
    @user.transactions.create!(name: 'Cash', amount: 10, date: Date.current, source: 'manual')
    assert_equal 1, @user.transactions.reportable.count
  end

  test "foreign connections and accounts cannot change tracking or partially save" do
    other = User.create!(email: 'other-tracking@example.test', password: 'test-password')
    private_item = other.plaid_items.create!(institution: @item.institution, plaid_item_id: 'other-item', access_token: 'fake-test-token')
    private_account = other.accounts.create!(plaid_item: private_item, plaid_account_id: 'private-card', name: 'Private', account_type: 'credit')
    patch tracking_plaid_item_path(private_item), params: { account_ids: [] }
    assert_response :not_found
    patch tracking_plaid_item_path(@item), params: { account_ids: [private_account.id] }
    assert_response :not_found
    assert @first.reload.tracked?
    assert @second.reload.tracked?
    assert private_account.reload.tracked?
  end

  test "provider account updates preserve user tracking and new accounts start included" do
    @second.update!(tracked: false)
    payloads = [@second.plaid_account_id, 'new-card'].map { |id| { 'account_id' => id, 'name' => 'Renamed card', 'type' => 'credit', 'balances' => { 'current' => 25, 'iso_currency_code' => 'USD' } } }
    Plaid::UpsertAccounts.call(user: @user, plaid_item: @item, accounts: payloads)
    assert_not @second.reload.tracked?
    assert_equal 25, @second.current_balance
    assert @user.accounts.find_by!(plaid_account_id: 'new-card').tracked?
  end
end
