require "test_helper"
require "minitest/mock"
require "csv"

class AutoCategorizationTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []
  setup do
    @user = User.create!(email: 'categorizer@example.com', password: 'test-password')
    @food = @user.categories.create!(name: 'Food & Dining')
    @groceries = @user.categories.create!(name: 'Groceries', parent: @food)
    @restaurants = @user.categories.create!(name: 'Restaurants', parent: @food)
    @shopping = @user.categories.create!(name: 'Shopping')
    post sign_in_path, params: { email: @user.email, password: 'test-password' }
  end
  def txn(code: nil, confidence: 'HIGH', **attrs)
    payload = code ? { 'personal_finance_category' => { 'detailed' => code, 'confidence_level' => confidence } } : {}
    @user.transactions.create!({source: 'manual', name: 'Neighborhood Market', amount: 25, date: Date.current, iso_currency_code: 'USD', raw_payload: payload}.merge(attrs))
  end
  def categorize
    PlaidApi::Client.stub(:from_env, -> { raise 'No live calls allowed' }) { AutoCategorizer.call(user: @user) }
  end
  def manual(**attrs)
    txn(**{category: @groceries, category_origin: 'manual', category_locked: true}.merge(attrs))
  end
  test 'high confidence bank categories map to existing categories and feed reports and budgets' do
    t = txn(code: 'FOOD_AND_DRINK_GROCERIES', amount: 40)
    assert_no_difference 'Category.count' do
      categorize
    end
    assert_equal @groceries, t.reload.category
    assert_equal 'provider', t.category_origin
    assert_not t.category_locked?
    assert_match(/high confidence/, t.category_reason)
    report = FinancialReport.new(user: @user, from: Date.current, to: Date.current)
    assert_equal [[@food, 40.to_d]], report.categories
    budget = @user.budgets.create!(category: @food, amount: 100, starts_on: Date.current, currency: 'USD')
    assert_equal 40.to_d, budget.spending(Date.current)
  end
  test 'a missing subcategory falls back only to its existing parent' do
    t = txn(code: 'FOOD_AND_DRINK_COFFEE', confidence: 'VERY_HIGH')
    categorize
    assert_equal @food, t.reload.category
  end
  test 'low confidence categories are suggestions and never become automatic assignments' do
    t = txn(code: 'FOOD_AND_DRINK_GROCERIES', confidence: 'LOW')
    result = categorize
    assert_nil t.reload.category
    assert_equal @groceries, t.suggested_category
    assert_equal 1, result.suggestions
    get transactions_path(flag: 'category_review')
    assert_response :success
    assert_select 'small', text: 'Category needs review'
    get transaction_path(t)
    assert_select '.flash', text: /needs review/
  end
  test 'unknown categories do not create arbitrary categories or guess from amount sign' do
    t = txn(code: 'OTHER_OTHER', amount: -200)
    no_signal = txn(name: 'Unknown transaction', amount: -300)
    assert_no_difference 'Category.count' do
      categorize
    end
    assert_nil t.reload.category
    assert_match(/No matching existing category/, t.category_suggestion_reason)
    assert_nil no_signal.reload.category
  end
  test 'manual imported existing and deliberately uncategorized choices stay protected' do
    rows = %w[manual import existing].map { |origin| txn(code: 'FOOD_AND_DRINK_GROCERIES', category: @shopping, category_origin: origin, category_locked: true) }
    blank = txn(code: 'FOOD_AND_DRINK_GROCERIES', category_locked: true, category_origin: 'manual')
    categorize
    rows.each { |t| assert_equal @shopping, t.reload.category }
    assert_nil blank.reload.category
  end
  test 'two unanimous manual merchant choices take precedence over bank category' do
    2.times { |i| manual(name: "Store reference #{i}", merchant_entity_id: 'merchant-store') }
    t = txn(name: 'Another reference', merchant_entity_id: 'merchant-store', code: 'GENERAL_MERCHANDISE_SUPERSTORES')
    categorize
    assert_equal @groceries, t.reload.category
    assert_equal 'merchant_history', t.category_origin
    assert_match(/2 previous/, t.category_reason)
    assert_not t.category_locked?
  end
  test 'a single correction conflicting history or generic descriptions do not train guesses' do
    manual(merchant_entity_id: 'one')
    single = txn(merchant_entity_id: 'one', code: 'FOOD_AND_DRINK_GROCERIES', confidence: 'LOW')
    manual(merchant_entity_id: 'mixed')
    manual(merchant_entity_id: 'mixed', category: @restaurants)
    mixed = txn(merchant_entity_id: 'mixed', code: 'FOOD_AND_DRINK_GROCERIES', confidence: 'LOW')
    2.times { manual(name: 'Debit card purchase') }
    generic = txn(name: 'Debit card purchase')
    categorize
    [single, mixed, generic].each { |t| assert_nil t.reload.category }
    assert_nil generic.merchant_key
  end
  test 'merchant name matching is exact and direction specific' do
    2.times { manual(merchant_name: 'Local Cafe') }
    same = txn(merchant_name: ' LOCAL   CAFE ')
    different = txn(merchant_name: 'Local Cafe Bakery')
    incoming = txn(merchant_name: 'Local Cafe', amount: -25)
    categorize
    assert_equal @groceries, same.reload.category
    assert_nil different.reload.category
    assert_nil incoming.reload.category
  end
  test 'remember merchant creates an exact rule and applies it to future and existing automatic transactions' do
    t = txn(merchant_entity_id: 'remember-me', code: 'FOOD_AND_DRINK_GROCERIES')
    existing = txn(merchant_entity_id: 'remember-me', name: 'Different descriptor', code: 'FOOD_AND_DRINK_GROCERIES')
    categorize
    patch transaction_path(t), params: { transaction: { category_id: @restaurants.id, remember_merchant: '1' } }
    assert_redirected_to transaction_path(t)
    assert_equal @restaurants, t.reload.category
    assert_equal 'manual', t.category_origin
    rule = @user.transaction_rules.last
    assert_equal t.merchant_key, rule.merchant_key
    assert_equal @restaurants, existing.reload.category
    future = txn(name: 'Yet another descriptor', merchant_entity_id: 'remember-me')
    assert_equal @restaurants, future.category
    assert_equal 'rule', future.category_origin
    other = txn(name: t.name, merchant_entity_id: 'different-merchant')
    assert_nil other.category
    get transaction_rules_path
    assert_select 'strong', text: /Exact merchant/
  end
  test 'notes save does not pin an automatic category and an explicit choice can be unlocked' do
    t = txn(code: 'FOOD_AND_DRINK_GROCERIES')
    categorize
    patch transaction_path(t), params: { transaction: { category_id: @groceries.id, lock_category: '0', notes: 'Checked' } }
    assert_not t.reload.category_locked?
    assert_equal 'provider', t.category_origin
    patch transaction_path(t), params: { transaction: { category_id: @restaurants.id, lock_category: '0' } }
    assert t.reload.category_locked?
    assert_equal @restaurants, t.category
    patch transaction_path(t), params: { transaction: { category_id: @restaurants.id, lock_category: '0' } }
    assert_not t.reload.category_locked?
    assert_equal @groceries, t.category
  end
  test 'bulk uncategorized is an intentional protected choice' do
    t = txn(code: 'FOOD_AND_DRINK_GROCERIES')
    categorize
    patch bulk_update_transactions_path, params: {ids: [t.id], bulk: {category_id: 'uncategorized'}}
    assert_nil t.reload.category
    assert t.category_locked?
    categorize
    assert_nil t.reload.category
  end
  test 'explicit import category mappings remain protected after categorization' do
    batch = @user.import_batches.create!(csv_text: "Date,Description,Amount,Category\n2026-09-01,Neighborhood Market,40,Old Food\n", settings: {'categories' => {'Old Food' => @restaurants.id.to_s}})
    Imports::CsvPreview.new(batch).commit!
    t = @user.transactions.last
    assert_equal @restaurants, t.category
    assert_equal 'import', t.category_origin
    assert t.category_locked?
  end
  test 'provider corrections recategorize automatic choices but never manual choices' do
    t = txn(code: 'FOOD_AND_DRINK_GROCERIES')
    categorize
    t.update!(raw_payload: {'personal_finance_category' => {'detailed' => 'GENERAL_MERCHANDISE_ONLINE_MARKETPLACES', 'confidence_level' => 'HIGH'}})
    categorize
    assert_equal @shopping, t.reload.category
    t.update!(raw_payload: {'personal_finance_category' => {'detailed' => 'FOOD_AND_DRINK_GROCERIES', 'confidence_level' => 'LOW'}})
    categorize
    assert_nil t.reload.category
    assert_equal @groceries, t.suggested_category
    patch transaction_path(t), params: {transaction: {category_id: @restaurants.id}}
    t.reload.update!(raw_payload: {'personal_finance_category' => {'detailed' => 'FOOD_AND_DRINK_GROCERIES', 'confidence_level' => 'HIGH'}})
    categorize
    assert_equal @restaurants, t.reload.category
  end
  test 'transfers card payments hidden duplicates pending records and split parents are skipped' do
    rows = [:transfer, :card_payment, :hidden, :duplicate, :pending].map { |flag| txn(code: 'FOOD_AND_DRINK_GROCERIES', **{flag => true}) }
    parent = txn(code: 'FOOD_AND_DRINK_GROCERIES', amount: 50)
    parent.replace_splits!([{name: 'Dining', amount: '20', category_id: @restaurants.id}, {name: 'Groceries', amount: '30', category_id: @groceries.id}])
    categorize
    rows.each { |t| assert_nil t.reload.category }
    assert_nil parent.reload.category
    assert_equal [@restaurants.id, @groceries.id].sort, parent.splits.pluck(:category_id).sort
    assert_equal 50.to_d, @user.transactions.reportable.sum(:amount)
  end
  test 'rules only affect existing categories when explicitly applied or remembered' do
    old = txn(code: 'FOOD_AND_DRINK_GROCERIES')
    categorize
    post transaction_rules_path, params: {transaction_rule: {match_text: 'Neighborhood', category_id: @restaurants.id, kind: 'regular'}}
    assert_equal @groceries, old.reload.category
    future = txn
    assert_equal @restaurants, future.category
    post transaction_rules_path, params: {transaction_rule: {match_text: 'Neighborhood', category_id: @shopping.id, kind: 'regular'}, apply_existing: '1'}
    assert_equal @shopping, old.reload.category
  end
  test 'merchant history and category writes never cross users' do
    other = User.create!(email: 'other-categories@example.com', password: 'test-password')
    private_category = other.categories.create!(name: 'Private category')
    2.times { other.transactions.create!(source: 'manual', name: 'Neighborhood Market', merchant_entity_id: 'shared-merchant', amount: 25, date: Date.current, category: private_category, category_locked: true, category_origin: 'manual') }
    t = txn(merchant_entity_id: 'shared-merchant')
    post categorize_transactions_path
    assert_nil t.reload.category
    assert_equal [private_category.id], other.transactions.distinct.pluck(:category_id)
    patch transaction_path(t), params: {transaction: {category_id: private_category.id, remember_merchant: '1'}}
    assert_response :not_found
    assert_equal 0, @user.transaction_rules.count
  end
  test 'repeated scans are stable and CSV exports disclose provenance' do
    t = txn(code: 'FOOD_AND_DRINK_GROCERIES')
    categorize
    before = t.reload.attributes
    categorize
    assert_equal before, t.reload.attributes
    get transactions_path(format: :csv)
    row = CSV.parse(response.body, headers: true).first
    assert_equal 'provider', row['CategoryOrigin']
    assert_match(/Bank category/, row['CategoryReason'])
  end
  test 'renaming an assigned personal category preserves its transactions' do
    t = txn(code: 'FOOD_AND_DRINK_GROCERIES')
    categorize
    patch category_path(@groceries), params: {category: {name: 'My groceries'}}
    assert_equal @groceries.id, t.reload.category_id
    assert t.category_locked?
    assert_equal 'My groceries', t.category.name
    categorize
    assert_equal @groceries.id, t.reload.category_id
  end

end
