require "test_helper"
require "minitest/mock"

class CashFlowClassificationTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []
  setup do
    @user = User.create!(email: "cash-flow@example.com", password: "test-password")
    institution = Institution.create!(name: 'Test bank', plaid_institution_id: 'cash-flow-bank')
    @item = @user.plaid_items.create!(institution: institution, plaid_item_id: 'cash-flow-item', access_token: 'fake-test-token')
    @checking = account('Household checking', 'depository', '1111')
    @savings = account('Emergency savings', 'depository', '2222')
    @card = account('Rewards card', 'credit', '3333')
    post sign_in_path, params: { email: @user.email, password: 'test-password' }
  end
  def account(name, type, mask)
    @user.accounts.create!(plaid_item: @item, plaid_account_id: "fake-#{mask}", name: name, account_type: type, mask: mask, iso_currency_code: 'USD')
  end
  def txn(name: 'Market', amount: 50, account: @checking, code: nil, confidence: 'HIGH', **attrs)
    payload = code ? { 'personal_finance_category' => { 'detailed' => code, 'confidence_level' => confidence } } : {}
    @user.transactions.create!({ source: 'manual', name: name, amount: amount, account: account, plaid_item: @item, date: Date.current, iso_currency_code: 'USD', raw_payload: payload }.merge(attrs))
  end
  def detect
    PlaidApi::Client.stub(:from_env, -> { raise 'Live provider access is forbidden in classification' }) do
      CashFlowClassifier.call(user: @user)
    end
  end
  test 'high confidence bank categories are excluded on both signs and currency reports agree' do
    incoming = txn(amount: -100, account: @savings, code: 'TRANSFER_IN_ACCOUNT_TRANSFER')
    outgoing = txn(amount: 100, code: 'TRANSFER_OUT_ACCOUNT_TRANSFER')
    payment = txn(amount: 75, code: 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT')
    purchase = txn(amount: 30)
    pay = txn(amount: -200, code: 'INCOME_SALARY')
    result = detect
    assert_equal 2, result.automatic_transfers
    assert_equal 1, result.automatic_card_payments
    assert incoming.reload.transfer?
    assert outgoing.reload.transfer?
    assert payment.reload.card_payment?
    assert_equal incoming.id, outgoing.matched_transaction_id
    report = FinancialReport.new(user: @user, from: Date.current, to: Date.current)
    assert_equal 30.to_d, report.spending
    assert_equal 200.to_d, report.income
    assert_equal [purchase.id, pay.id].sort, @user.transactions.reportable.ids.sort
    budget_category = @user.categories.create!(name: 'All activity')
    @user.transactions.update_all(category_id: budget_category.id)
    budget = @user.budgets.create!(category: budget_category, amount: 100, starts_on: Date.current, currency: 'USD')
    assert_equal 30.to_d, budget.spending(Date.current)
  end
  test 'low confidence categories stay included as review suggestions without corroboration' do
    t = txn(code: 'TRANSFER_OUT_ACCOUNT_TRANSFER', confidence: 'LOW')
    detect
    assert_not t.reload.transfer?
    assert_equal 'transfer', t.suggested_classification
    assert_equal 50.to_d, @user.transactions.reportable.sum(:amount)
    get transactions_path(flag: 'suggested')
    assert_response :success
    assert_select 'small', text: /Suggested transfer/
  end
  test 'named account matching disambiguates repeated equal vault movements' do
    a = account('College vault', 'depository', '4444')
    b = account('Holiday vault', 'depository', '5555')
    out_a = txn(name: 'To College vault', amount: 5, code: 'TRANSFER_OUT_ACCOUNT_TRANSFER', confidence: 'LOW')
    out_b = txn(name: 'To Holiday vault', amount: 5, code: 'TRANSFER_OUT_ACCOUNT_TRANSFER', confidence: 'LOW')
    in_a = txn(name: 'From Household checking', amount: -5, account: a, code: 'TRANSFER_IN_ACCOUNT_TRANSFER')
    in_b = txn(name: 'From Household checking', amount: -5, account: b, code: 'TRANSFER_IN_ACCOUNT_TRANSFER')
    detect
    assert out_a.reload.transfer?
    assert out_b.reload.transfer?
    assert_equal in_a.id, out_a.matched_transaction_id
    assert_equal in_b.id, out_b.matched_transaction_id
  end
  test 'equal amounts alone never classify purchases refunds salary or P2P' do
    purchase = txn(name: 'Store', amount: 50)
    refund = txn(name: 'Refund', amount: -50, account: @card)
    p2p = txn(name: 'Venmo', amount: 30, code: 'TRANSFER_OUT_TRANSFER_OUT_FROM_APPS')
    salary = txn(name: 'Salary', amount: -30, account: @savings, code: 'INCOME_SALARY')
    detect
    [purchase, refund, p2p, salary].each { |t| assert_not t.reload.excluded? }
  end
  test 'ambiguous amounts pending duplicates different currencies dates and same accounts never pair' do
    low = txn(code: 'TRANSFER_OUT_ACCOUNT_TRANSFER', confidence: 'LOW')
    txn(amount: -50, account: @savings, code: 'TRANSFER_IN_ACCOUNT_TRANSFER', confidence: 'LOW')
    txn(amount: -50, account: @card, code: 'TRANSFER_IN_ACCOUNT_TRANSFER', confidence: 'LOW')
    detect
    assert_not low.reload.transfer?
    assert_nil low.matched_transaction_id
    @user.transactions.destroy_all
    low = txn(code: 'TRANSFER_OUT_ACCOUNT_TRANSFER', confidence: 'LOW')
    txn(amount: -50, account: @savings, code: 'TRANSFER_IN_ACCOUNT_TRANSFER', pending: true)
    txn(amount: -50, account: @savings, code: 'TRANSFER_IN_ACCOUNT_TRANSFER', duplicate: true)
    txn(amount: -50, account: @savings, code: 'TRANSFER_IN_ACCOUNT_TRANSFER', hidden: true)
    txn(amount: -50, account: @savings, code: 'TRANSFER_IN_ACCOUNT_TRANSFER', iso_currency_code: 'CAD')
    txn(amount: -50, account: @savings, code: 'TRANSFER_IN_ACCOUNT_TRANSFER', date: 4.days.ago.to_date)
    txn(amount: -50, account: @checking, code: 'TRANSFER_IN_ACCOUNT_TRANSFER')
    detect
    assert_not low.reload.transfer?
    assert_nil low.matched_transaction_id
  end
  test 'card descriptions exclude both payment sides but never purchases interest fees or refunds' do
    debit = txn(name: 'Credit Card Payment', amount: 80)
    credit = txn(name: 'AUTOMATIC PAYMENT THANK YOU', amount: -80, account: @card)
    fee = txn(name: 'Credit card payment fee', amount: 5, account: @card)
    refund = txn(name: 'Online payment refund', amount: -9, account: @card)
    interest = txn(name: 'Credit card payment interest', amount: 7)
    detect
    assert debit.reload.card_payment?
    assert credit.reload.card_payment?
    [fee, refund, interest].each { |t| assert_not t.reload.card_payment? }
    assert_equal credit.id, debit.matched_transaction_id
  end
  test 'manual regular override survives scans and bank updates and can return to automatic' do
    t = txn(code: 'TRANSFER_OUT_ACCOUNT_TRANSFER', source: 'plaid', plaid_transaction_id: 'override-txn')
    detect
    assert t.reload.transfer?
    patch transaction_path(t), params: { transaction: { classification_choice: 'regular' } }
    assert t.reload.classification_override?
    assert_not t.transfer?
    Plaid::UpsertTransactions.call(user: @user, plaid_item: @item, transactions: [{ 'transaction_id' => 'override-txn', 'account_id' => @checking.plaid_account_id, 'name' => 'Transfer', 'amount' => 50, 'date' => Date.current.to_s, 'iso_currency_code' => 'USD', 'personal_finance_category' => { 'detailed' => 'TRANSFER_OUT_ACCOUNT_TRANSFER', 'confidence_level' => 'VERY_HIGH' } }])
    assert_not t.reload.transfer?
    patch transaction_path(t), params: { transaction: { classification_choice: 'automatic' } }
    assert t.reload.transfer?
    assert_not t.classification_override?
    assert_equal 'automatic', t.classification_origin
  end
  test 'manual flags and transaction rules are preserved' do
    manual = txn(transfer: true, classification_override: true, classification_origin: 'manual')
    @user.transaction_rules.create!(match_text: 'Market', kind: 'card_payment')
    ruled = txn
    detect
    assert manual.reload.transfer?
    assert_equal 'manual', manual.classification_origin
    assert ruled.reload.card_payment?
    assert_equal 'rule', ruled.classification_origin
  end
  test 'automatic stale matches clear on corrections and removals and splits inherit exclusions' do
    a = txn(name: 'To Emergency savings', amount: 50)
    b = txn(name: 'Transfer from Household checking', amount: -50, account: @savings)
    a.replace_splits!([{ name: 'Part 1', amount: '20' }, { name: 'Part 2', amount: '30' }])
    detect
    assert a.reload.transfer?
    assert_equal 0, @user.transactions.reportable.count
    b.destroy!
    a.update!(name: 'Store purchase')
    detect
    assert_not a.reload.transfer?
    assert_nil a.matched_transaction_id
    assert_equal 50.to_d, @user.transactions.reportable.sum(:amount)
  end
  test 'imports retain category intent and auto classify without changing balances' do
    batch = @user.import_batches.create!(csv_text: "Date,Description,Amount,Category,Account\n2026-09-01,Card bill,75,Credit Card Payment,Old checking\n")
    assert_no_difference ['Account.count', 'BalanceSnapshot.count', 'PlaidItem.count'] do
      Imports::CsvPreview.new(batch).commit!
    end
    t = @user.transactions.last
    assert t.card_payment?
    assert_equal 'automatic', t.classification_origin
    assert_nil t.account_id
  end
  test 'scan endpoint scopes both matching and writes to signed in user' do
    other = User.create!(email: 'other-classifier@example.com', password: 'test-password')
    other_t = other.transactions.create!(source: 'manual', name: 'Credit card payment', amount: 50, date: Date.current)
    t = txn(code: 'TRANSFER_OUT_ACCOUNT_TRANSFER')
    post classify_transactions_path
    assert_redirected_to transactions_path
    assert t.reload.transfer?
    assert_not other_t.reload.card_payment?
    get transaction_path(t)
    assert_select 'select[name="transaction[classification_choice]"]'
    assert_select 'p', text: /Bank account-transfer category/
  end
  test 'closest posting date resolves recurring equal transfers without arbitrary tie breaking' do
    out_today = txn(name: 'To Emergency savings', amount: 5, code: 'TRANSFER_OUT_ACCOUNT_TRANSFER', confidence: 'LOW')
    in_today = txn(name: 'Transfer in', amount: -5, account: @savings, code: 'TRANSFER_IN_ACCOUNT_TRANSFER')
    out_prior = txn(name: 'To Emergency savings', amount: 5, code: 'TRANSFER_OUT_ACCOUNT_TRANSFER', confidence: 'LOW', date: 2.days.ago.to_date)
    in_prior = txn(name: 'Transfer in', amount: -5, account: @savings, code: 'TRANSFER_IN_ACCOUNT_TRANSFER', date: 2.days.ago.to_date)
    detect
    assert_equal in_today.id, out_today.reload.matched_transaction_id
    assert_equal in_prior.id, out_prior.reload.matched_transaction_id
    first = @user.transactions.order(:id).pluck(:id, :transfer, :card_payment, :matched_transaction_id, :updated_at)
    detect
    assert_equal first, @user.transactions.order(:id).pluck(:id, :transfer, :card_payment, :matched_transaction_id, :updated_at)
  end
  test 'an imported alias of a linked account is never treated as a different owned account' do
    t = txn(code: 'TRANSFER_OUT_ACCOUNT_TRANSFER', confidence: 'LOW')
    txn(name: 'Transfer', amount: -50, account: nil, plaid_item: nil, source: 'import', source_account_name: @checking.name, code: 'TRANSFER_IN_ACCOUNT_TRANSFER', confidence: 'LOW')
    detect
    assert_not t.reload.transfer?
    assert_nil t.matched_transaction_id
  end

  test 'an explicit regular choice takes precedence over a transfer rule on manual creation' do
    @user.transaction_rules.create!(match_text: 'Market', kind: 'transfer')
    post transactions_path, params: { transaction: { name: 'Market', amount: 50, date: Date.current, iso_currency_code: 'USD', classification_choice: 'regular' } }
    t = @user.transactions.last
    assert t.classification_override?
    assert_equal 'manual', t.classification_origin
    assert_not t.transfer?
    detect
    assert_not t.reload.transfer?
  end

end
