require "test_helper"

class AccountRulesTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []
  setup do
    @user = User.create!(email: 'account-rules@example.com', password: 'test-password')
    @category = @user.categories.create!(name: 'Business expenses')
    @other_category = @user.categories.create!(name: 'Personal spending')
    institution = Institution.create!(name: 'Test bank', plaid_institution_id: 'rules-bank')
    @item = @user.plaid_items.create!(institution: institution, plaid_item_id: 'rules-item', access_token: 'fake-test-token')
    @business = @user.accounts.create!(plaid_item: @item, plaid_account_id: 'rules-business', name: 'Business checking', account_type: 'depository')
    @personal = @user.accounts.create!(plaid_item: @item, plaid_account_id: 'rules-personal', name: 'Personal checking', account_type: 'depository')
    post sign_in_path, params: {email: @user.email, password: 'test-password'}
  end
  def txn(**attrs)
    @user.transactions.create!({source: 'manual', account: @business, plaid_item: @item, name: 'Office store', amount: 25, date: Date.current, iso_currency_code: 'USD'}.merge(attrs))
  end
  def rule(**attrs)
    @user.transaction_rules.create!({match_text: 'Office', category: @category, kind: 'regular'}.merge(attrs))
  end
  test 'account only rules categorize the selected account and leave other accounts alone' do
    post transaction_rules_path, params: {transaction_rule: {account_id: @business.id, category_id: @category.id, kind: 'regular'}}
    assert_redirected_to transaction_rules_path
    r = @user.transaction_rules.last
    assert_nil r.match_text
    matching = txn(name: 'Any description')
    nonmatching = txn(account: @personal)
    assert_equal @category, matching.category
    assert_nil nonmatching.category
    assert_equal 'Your account rule', matching.category_reason
  end
  test 'description and account conditions combine with AND and ignore description case' do
    r = rule(match_text: 'OFFICE', account: @business)
    assert r.matches?(txn(name: 'Office supplies'))
    assert_not r.matches?(txn(name: 'Coffee'))
    assert_not r.matches?(txn(name: 'Office supplies', account: @personal))
    assert_not r.matches?(txn(name: 'Office supplies', account: nil, plaid_item: nil, source_account_name: @business.name))
  end
  test 'description operators are literal and predictable' do
    t = txn(name: 'Office [store] supplies')
    {'contains' => '[STORE]', 'equals' => 'office [store] supplies', 'starts_with' => 'OFFICE', 'ends_with' => 'SUPPLIES'}.each do |operator, text|
      r = rule(description_operator: operator, match_text: text)
      assert r.matches?(t), operator
    end
    assert_not rule(description_operator: 'equals', match_text: 'Office').matches?(t)
    assert_not rule(description_operator: 'contains', match_text: '.*').matches?(t)
  end
  test 'source account rules work without linked accounts and require exact names' do
    r = rule(match_text: nil, source_account_name: ' Old Checking ')
    assert r.matches?(txn(account: nil, plaid_item: nil, source: 'import', source_account_name: 'old checking'))
    assert_not r.matches?(txn(account: nil, plaid_item: nil, source: 'import', source_account_name: 'old checking business'))
    assert_not r.matches?(txn)
    batch = @user.import_batches.create!(csv_text: "Date,Description,Amount,Account\n2026-09-01,Supplies,33,Old Checking\n")
    Imports::CsvPreview.new(batch).commit!
    assert_equal @category, @user.transactions.last.category
  end
  test 'preview shows matching history without saving a rule or changing transactions' do
    match = txn
    other = txn(account: @personal)
    original = @user.transactions.order(:id).pluck(:id, :category_id, :updated_at)
    assert_no_difference 'TransactionRule.count' do
      post transaction_rules_path, params: {preview: '1', transaction_rule: {account_id: @business.id, match_text: 'office', category_id: @category.id, kind: 'regular'}}
    end
    assert_response :success
    assert_select 'h2', text: 'Preview · 1 matching transaction'
    assert_select 'tbody tr', count: 1
    assert_equal original, @user.transactions.order(:id).pluck(:id, :category_id, :updated_at)
    assert_nil match.reload.category
    assert_nil other.reload.category
  end
  test 'invalid empty conflicting and unsupported conditions are rejected' do
    [{}, {account_id: @business.id, source_account_name: 'Old checking'}, {match_text: 'Office', description_operator: 'regex'}].each do |conditions|
      assert_no_difference 'TransactionRule.count' do
        post transaction_rules_path, params: {transaction_rule: conditions.merge(kind: 'regular', category_id: @category.id)}
      end
      assert_response :unprocessable_entity
      assert_select '[role=alert]'
    end
  end
  test 'scoped history application updates only matches and preserves manual categories' do
    a = txn
    manual = txn(category: @other_category, category_locked: true, category_origin: 'manual')
    b = txn(account: @personal)
    post transaction_rules_path, params: {apply_existing: '1', transaction_rule: {account_id: @business.id, category_id: @category.id, kind: 'regular', tags: 'business'}}
    assert_equal @category, a.reload.category
    assert_equal @other_category, manual.reload.category
    assert_nil b.reload.category
    assert_equal 'business', a.tags
    assert_equal '', b.tags
    AutoCategorizer.call(user: @user)
    assert_equal @category, a.reload.category
  end
  test 'editing a rule affects new records and optional history application is explicit' do
    r = rule(match_text: 'Does not match')
    old = txn
    patch transaction_rule_path(r), params: {transaction_rule: {match_text: 'Office', account_id: @business.id, category_id: @category.id, kind: 'regular'}}
    assert_redirected_to transaction_rules_path
    assert_nil old.reload.category
    future = txn
    assert_equal @category, future.category
    patch transaction_rule_path(r), params: {apply_existing: '1', transaction_rule: {category_id: @other_category.id}}
    assert_equal @other_category, old.reload.category
    assert_equal @other_category, future.reload.category
  end
  test 'editing preview leaves the saved rule untouched' do
    r = rule
    txn(account: @personal)
    post_count = TransactionRule.count
    patch transaction_rule_path(r), params: {preview: '1', transaction_rule: {account_id: @personal.id, category_id: @other_category.id}}
    assert_response :success
    assert_nil r.reload.account_id
    assert_equal @category, r.category
    assert_equal post_count, TransactionRule.count
  end
  test 'remembered merchant preferences can be scoped to one account' do
    sample = txn(merchant_entity_id: 'exact-store')
    r = rule(merchant_key: sample.merchant_key, match_text: 'Office store', account: @business)
    assert r.matches?(sample)
    assert_not r.matches?(txn(merchant_entity_id: 'exact-store', account: @personal))
    assert_not r.matches?(txn(merchant_entity_id: 'different-store'))
  end
  test 'foreign accounts rules and categories are inaccessible' do
    other = User.create!(email: 'foreign-rules@example.com', password: 'test-password')
    institution = Institution.create!(name: 'Other bank', plaid_institution_id: 'foreign-rules-bank')
    item = other.plaid_items.create!(institution: institution, plaid_item_id: 'foreign-rules-item', access_token: 'fake-test-token')
    account = other.accounts.create!(plaid_item: item, plaid_account_id: 'foreign-rules-account', name: 'Private account', account_type: 'depository')
    assert_no_difference 'TransactionRule.count' do
      post transaction_rules_path, params: {transaction_rule: {account_id: account.id, category_id: @category.id, kind: 'regular'}}
    end
    assert_response :unprocessable_entity
    foreign = other.transaction_rules.create!(match_text: 'Private', kind: 'regular')
    patch transaction_rule_path(foreign), params: {transaction_rule: {match_text: 'Changed'}}
    assert_response :not_found
    delete transaction_rule_path(foreign)
    assert_response :not_found
    assert_equal 'Private', foreign.reload.match_text
    assert_not rule.matches?(other.transactions.new(name: 'Office store'))
  end
  test 'deleting an account removes scoped rules instead of broadening their match' do
    r = rule(account: @business)
    @business.destroy!
    assert_not TransactionRule.exists?(r.id)
  end
  test 'explicit history application also preserves mapped import categories' do
    mapped = txn(source: 'import', category: @other_category, category_locked: true, category_origin: 'import')
    post transaction_rules_path, params: {apply_existing: '1', transaction_rule: {account_id: @business.id, category_id: @category.id, kind: 'regular'}}
    assert_equal @other_category, mapped.reload.category
    assert_equal 'import', mapped.category_origin
  end

end
