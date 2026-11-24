require "test_helper"

class RecurringDetectorTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  setup do
    @today = Date.new(2026, 11, 11)
    @user = User.create!(email: 'recurring-patterns@example.test', password: 'test-password')
  end

  def charge(date, **attrs)
    @user.transactions.create!({ name: 'Cloud Storage', amount: 10, date: date, source: 'manual', iso_currency_code: 'USD', source_account_name: 'Card A' }.merge(attrs))
  end

  def suggestions
    RecurringDetector.new(@user, today: @today).suggestions
  end

  test "three stable monthly transactions create an explanation without writing anything" do
    [9, 10, 11].each { |month| charge(Date.new(2026, month, 1)) }
    assert_no_difference ['RecurringItem.count', 'Transaction.count', 'BalanceSnapshot.count'] do
      results = suggestions
      assert_equal 1, results.size
      assert_equal 'monthly', results.first.frequency
      assert_equal 3, results.first.history.size
      assert_equal 10, results.first.minimum
    end
  end

  test "two transactions and irregular shopping do not become suggestions" do
    [1, 9, 16, 20].each { |day| charge(Date.new(2026, 10, day)) }
    [9, 10].each { |month| charge(Date.new(2026, month, 1), name: 'New subscription') }
    assert_empty suggestions
  end

  test "pending hidden duplicate and transfer entries are ignored" do
    charge(Date.new(2026, 9, 1))
    charge(Date.new(2026, 10, 1))
    %i[pending hidden duplicate transfer card_payment].each { |flag| charge(Date.new(2026, 11, 1), flag => true) }
    assert_empty suggestions
  end

  test "account currency and income direction remain separate" do
    [9, 10, 11].each do |month|
      date = Date.new(2026, month, 1)
      charge(date)
      charge(date, source_account_name: 'Card B', amount: 12)
      charge(date, iso_currency_code: 'CAD', amount: 15)
      charge(date, amount: -100)
    end
    assert_equal 4, suggestions.size
    assert_equal 4, suggestions.map(&:key).uniq.size
  end

  test "dismissal and confirmation prevent repeat suggestions without changing history" do
    entries = [9, 10, 11].map { |month| charge(Date.new(2026, month, 1)) }
    suggestion = suggestions.first
    dismissal = @user.recurring_dismissals.create!(name: 'Cloud Storage', detection_key: suggestion.key)
    assert_empty suggestions
    dismissal.destroy!
    assert_equal 1, suggestions.size
    @user.recurring_items.create!(name: 'Cloud Storage', amount: 10, next_on: @today, detection_key: suggestion.key)
    assert_empty suggestions
    assert_equal entries.map(&:id), @user.transactions.order(:id).pluck(:id)
  end

  test "stale patterns extreme amount changes and same-day ambiguity require manual entry" do
    [1, 2, 3].each { |month| charge(Date.new(2026, month, 1)) }
    [9, 10, 11].each_with_index { |month, index| charge(Date.new(2026, month, 1), name: 'Mixed Store', amount: index == 2 ? 200 : 10) }
    [9, 10, 11].each { |month| 2.times { charge(Date.new(2026, month, 1), name: 'Ambiguous Vendor') } }
    assert_empty suggestions
  end

  test "another user's matching history does not complete this user's pattern" do
    charge(Date.new(2026, 9, 1))
    charge(Date.new(2026, 10, 1))
    other = User.create!(email: 'other-recurring@example.test', password: 'test-password')
    other.transactions.create!(name: 'Cloud Storage', amount: 10, date: Date.new(2026, 11, 1), source: 'manual', iso_currency_code: 'USD', source_account_name: 'Card A')
    assert_empty suggestions
  end
end
