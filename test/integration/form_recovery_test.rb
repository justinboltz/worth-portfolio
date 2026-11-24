require "test_helper"

class FormRecoveryTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  setup do
    @user = User.create!(email: "form-recovery@example.test", password: "test-password")
    @category = @user.categories.create!(name: "Household")
    post sign_in_path, params: { email: @user.email, password: "test-password" }
  end

  test "invalid transaction edits retain input and do not change stored values" do
    entry = @user.transactions.create!(name: "Original", amount: 25, date: Date.current, source: "manual", iso_currency_code: "USD")
    patch transaction_path(entry), params: { transaction: { name: "Revised description", amount: "", notes: "Keep these notes" } }
    assert_response :unprocessable_entity
    assert_select '.form-errors[role=alert]', text: /Amount/
    assert_select 'input[name="transaction[name]"][value="Revised description"]'
    assert_select 'textarea', text: 'Keep these notes'
    assert_equal 'Original', entry.reload.name
    assert_equal 25, entry.amount
  end

  test "invalid splits retain every row and preserve the existing split" do
    entry = @user.transactions.create!(name: "Original", amount: 25, date: Date.current, source: "manual", iso_currency_code: "USD")
    entry.replace_splits!([{ name: 'First', amount: '10' }, { name: 'Second', amount: '15' }])
    original_ids = entry.splits.pluck(:id)
    rows = 5.times.to_h { |index| [index.to_s, { name: "Part #{index + 1}", amount: '6' }] }
    post split_transaction_path(entry), params: { splits: rows }
    assert_response :unprocessable_entity
    assert_select '[role=alert]', text: /add up/
    assert_select '.split-rows input[value="Part 5"]'
    assert_equal original_ids, entry.splits.reload.pluck(:id)
    assert_equal [10.to_d, 15.to_d], entry.splits.map(&:amount)
  end

  test "budget create and update errors preserve entered fields and selected month" do
    post budgets_path, params: { month: '2026-09', budget: { category_id: @category.id, amount: '-5', starts_on: '2026-09-01', currency: 'CAD' } }
    assert_response :unprocessable_entity
    assert_equal(-5.to_d, css_select('input[name="budget[amount]"]').last['value'].to_d)
    assert_select 'select[name="budget[currency]"] option[selected][value=CAD]'
    assert_equal 0, @user.budgets.count
    budget = @user.budgets.create!(category: @category, amount: 100, starts_on: Date.new(2026, 8, 1), currency: 'CAD')
    patch budget_path(budget), params: { month: '2026-09', budget: { amount: '' } }
    assert_response :unprocessable_entity
    assert_select '.editor-details[open] .form-errors', text: /Amount/
    assert_select 'input[name=month][value="2026-09"]'
    assert_equal 100, budget.reload.amount
  end

  test "category create and update errors keep submitted values" do
    post categories_path, params: { category: { name: @category.name } }
    assert_response :unprocessable_entity
    assert_select 'input[name="category[name]"][value=Household]'
    assert_select '.form-errors', text: /taken/
    second = @user.categories.create!(name: 'Second')
    patch category_path(second), params: { category: { name: @category.name } }
    assert_response :unprocessable_entity
    assert_select '.category-actions .form-errors', text: /taken/
    assert_equal 'Second', second.reload.name
  end

  test "invalid rule edits show a single form for that rule" do
    rule = @user.transaction_rules.create!(match_text: 'Market', category: @category, kind: 'regular')
    patch transaction_rule_path(rule), params: { transaction_rule: { match_text: '', account_id: '', source_account_name: '' } }
    assert_response :unprocessable_entity
    assert_select "form[action='#{transaction_rule_path(rule)}']", count: 1
    ids = css_select('[id]').map { |element| element['id'] }
    assert_equal ids.uniq, ids
  end
end
