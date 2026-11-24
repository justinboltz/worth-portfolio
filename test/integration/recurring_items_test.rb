require "test_helper"

class RecurringItemsTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []
  setup do
    @user = User.create!(email: 'recurring-ui@example.test', password: 'test-password')
    post sign_in_path, params: { email: @user.email, password: 'test-password' }
  end

  def attributes(**attrs)
    { name: 'Internet', amount: '65', currency: 'USD', frequency: 'monthly', direction: 'expense', next_on: Date.current, status: 'active' }.merge(attrs)
  end

  test "manual bills and income work without creating actual transactions" do
    assert_no_difference ['Transaction.count', 'BalanceSnapshot.count', 'PlaidItem.count'] do
      post recurring_items_path, params: { recurring_item: attributes }
      assert_redirected_to recurring_items_path
      post recurring_items_path, params: { recurring_item: attributes(name: 'Paycheck', direction: 'income', amount: '2000', frequency: 'biweekly') }
      assert_redirected_to recurring_items_path
    end
    assert_equal 2, @user.recurring_items.count
    get recurring_items_path
    assert_response :success
    assert_select '.upcoming-list li', minimum: 3
    assert_select '.metric', text: /Expected income/
    assert_select '.card-heading', text: /Estimates do not change/
  end

  test "confirmations are explicit and protected matching fields cannot be forged" do
    source = @user.transactions.create!(name: 'Streaming Plus', amount: 12, source: 'manual', date: Date.current, iso_currency_code: 'USD', source_account_name: 'Card A')
    get new_recurring_item_path, params: { transaction_id: source.id, frequency: 'monthly' }
    assert_response :success
    assert_equal 0, @user.recurring_items.count
    post recurring_items_path, params: { transaction_id: source.id, recurring_item: attributes(name: 'My streaming plan', currency: 'CAD', direction: 'income', amount: '15', detection_key: 'forged') }
    item = @user.recurring_items.last
    assert_equal 'USD', item.currency
    assert_equal 'expense', item.direction
    assert_equal 15, item.amount
    assert_equal RecurringDetector.key(source), item.detection_key
    assert_equal 12, source.reload.amount
    post recurring_items_path, params: { transaction_id: source.id, recurring_item: attributes }
    assert_response :unprocessable_entity
    assert_equal 1, @user.recurring_items.count
  end

  test "paused schedules disappear from outlook and resume without changing transactions" do
    item = @user.recurring_items.create!(attributes)
    patch recurring_item_path(item), params: { recurring_item: { status: 'paused' } }
    assert_redirected_to recurring_items_path
    get recurring_items_path
    assert_select '.upcoming-list', count: 0
    assert_select '.recurring-tile', text: /Paused/
    patch recurring_item_path(item), params: { recurring_item: { status: 'active' } }
    get recurring_items_path
    assert_select '.upcoming-list li', minimum: 1
    assert_equal 0, @user.transactions.count
  end

  test "invalid input is retained and private records stay private" do
    post recurring_items_path, params: { recurring_item: attributes(name: 'Keep my name', amount: '-1') }
    assert_response :unprocessable_entity
    assert_select '.form-errors[role=alert]'
    assert_select 'input[name="recurring_item[name]"][value="Keep my name"]'
    other = User.create!(email: 'private-recurring@example.test', password: 'test-password')
    item = other.recurring_items.create!(attributes)
    get edit_recurring_item_path(item)
    assert_response :not_found
    patch recurring_item_path(item), params: { recurring_item: { amount: 1 } }
    assert_response :not_found
    delete recurring_item_path(item)
    assert_response :not_found
    source = other.transactions.create!(name: 'Private subscription', amount: 10, source: 'manual', date: Date.current)
    post dismiss_recurring_items_path, params: { transaction_id: source.id }
    assert_response :not_found
    get new_recurring_item_path, params: { transaction_id: source.id }
    assert_response :not_found
    assert_equal 65, item.reload.amount
  end

  test "amount changes are visible without changing the confirmed estimate" do
    source = @user.transactions.create!(name: 'Cloud Storage', amount: 12, source: 'manual', date: Date.current, iso_currency_code: 'USD', source_account_name: '')
    item = @user.recurring_items.create!(attributes(name: 'Cloud Storage', amount: 10, merchant_key: source.merchant_key, detection_key: RecurringDetector.key(source), source_account_name: ''))
    get recurring_items_path
    assert_select '.amount-change', text: /Latest: \$12.00/
    assert_equal 10, item.reload.amount
    get edit_recurring_item_path(item)
    assert_response :success
    assert_select '.recurring-history', text: /Cloud Storage/
  end

  test "dismissed suggestions can be restored and stopping tracking preserves transactions" do
    source = @user.transactions.create!(name: 'Cloud Storage', amount: 10, source: 'manual', date: Date.current, iso_currency_code: 'USD')
    post dismiss_recurring_items_path, params: { transaction_id: source.id }
    dismissal = @user.recurring_dismissals.last
    get recurring_items_path
    assert_response :success
    assert_select "form[action='#{restore_suggestion_recurring_items_path(dismissal)}']"
    delete restore_suggestion_recurring_items_path(dismissal)
    assert_equal 0, @user.recurring_dismissals.count
    item = @user.recurring_items.create!(attributes(merchant_key: source.merchant_key, detection_key: RecurringDetector.key(source)))
    assert_no_difference 'Transaction.count' do
      delete recurring_item_path(item)
    end
    assert_equal 1, @user.recurring_dismissals.count
    assert_equal 0, @user.recurring_items.count
  end
end
