require "test_helper"

class RecurringItemTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  setup { @user = User.create!(email: 'recurring-calendar@example.test', password: 'test-password') }

  def schedule(**attrs)
    @user.recurring_items.create!({ name: 'Rent', amount: 100, currency: 'USD', next_on: Date.new(2026, 1, 31), frequency: 'monthly' }.merge(attrs))
  end

  test "monthly dates keep their anchor through short months" do
    item = schedule
    assert_equal [Date.new(2026, 1, 31), Date.new(2026, 2, 28), Date.new(2026, 3, 31)], item.occurrences(from: Date.new(2026, 1, 1), to: Date.new(2026, 3, 31))
    assert_equal Date.new(2026, 3, 31), item.next_occurrence(Date.new(2026, 3, 1))
  end

  test "month end schedules retain the final day after a February anchor" do
    item = schedule(next_on: Date.new(2026, 2, 28), month_end: true)
    assert_equal Date.new(2026, 3, 31), item.next_occurrence(Date.new(2026, 3, 1))
    assert_equal Date.new(2028, 2, 29), item.next_occurrence(Date.new(2028, 2, 1))
  end

  test "weekly and biweekly schedules count each occurrence and paused items count none" do
    item = schedule(next_on: Date.new(2026, 11, 1), frequency: 'weekly')
    assert_equal [1, 8, 15, 22, 29], item.occurrences(from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30)).map(&:day)
    item.update!(frequency: 'biweekly')
    assert_equal [1, 15, 29], item.occurrences(from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30)).map(&:day)
    item.update!(status: 'paused')
    assert_empty item.occurrences(from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30))
  end

  test "quarterly and yearly schedules cross years correctly" do
    item = schedule(next_on: Date.new(2024, 2, 29), frequency: 'yearly', month_end: true)
    assert_equal Date.new(2028, 2, 29), item.next_occurrence(Date.new(2028, 1, 1))
    item.update!(next_on: Date.new(2026, 11, 30), frequency: 'quarterly')
    assert_equal Date.new(2027, 2, 28), item.next_occurrence(Date.new(2027, 1, 1))
  end

  test "invalid schedules fail validation before touching the database" do
    item = @user.recurring_items.new(name: '', amount: 0, currency: 'BOGUS', direction: 'transfer', frequency: 'daily', next_on: nil, account_id: -1)
    assert_not item.valid?
    %i[name amount currency direction frequency next_on account].each { |key| assert item.errors[key].any?, key.to_s }
  end
end
