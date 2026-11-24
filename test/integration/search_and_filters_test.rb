require "test_helper"
require "csv"

class SearchAndFiltersTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  setup do
    @user = User.create!(email: "search@example.com", password: "test-password")
    @parent = @user.categories.create!(name: "Transport")
    @category = @user.categories.create!(name: "Fuel", parent: @parent)
    post sign_in_path, params: { email: @user.email, password: "test-password" }
  end

  def entry(**attributes)
    @user.transactions.create!({ name: "Purchase", date: Date.current, amount: 25, source: "manual", iso_currency_code: "USD", category: @category }.merge(attributes))
  end

  test "duplicate review suggests nearby bank and import dates only within the posting window" do
    bank = entry(name: "Fuel", source: "plaid")
    delayed = entry(name: "Fuel", source: "import", date: Date.current - 14)
    entry(name: "Fuel", source: "import", date: Date.current - 15)
    entry(name: "Fuel", source: "plaid", date: Date.current + 1)
    assert_equal [[bank.id, delayed.id]], DuplicateTransactionReview.new(@user).groups.map { |group| group.map(&:id) }
    get duplicates_transactions_path
    assert_response :success
    assert_select "td", text: delayed.date.to_s
    assert_not delayed.reload.duplicate?
  end

  test "duplicate review groups matching entries and keeps one original" do
    original = entry(name: "Fuel Stop")
    copy = entry(name: "  FUEL  STOP ", source: "import")
    unrelated = entry(name: "Different merchant")
    get duplicates_transactions_path
    assert_response :success
    assert_select "input[name='ids[]']", count: 2
    patch bulk_update_transactions_path, params: { duplicate_review: "1", ids: [original.id, copy.id] }
    assert_not copy.reload.duplicate?
    patch bulk_update_transactions_path, params: { duplicate_review: "1", ids: [copy.id] }
    assert_redirected_to duplicates_transactions_path
    assert copy.reload.duplicate?
    assert_not original.reload.duplicate?
    assert_not unrelated.reload.duplicate?
    assert_not @user.transactions.reportable.exists?(copy.id)
  end

  test "search finds notes merchants imported accounts and literal wildcard characters" do
    wanted = entry(name: "Purchase 100%", notes: "Family road trip", merchant_name: "Fuel station", source_account_name: "Old checking")
    entry(name: "Other purchase", category: nil)
    ["road trip", "fuel station", "old checking", "100%", "Fuel"].each do |query|
      get transactions_path, params: { q: query }
      assert_response :success
      assert_select 'tbody tr', count: 1
      assert_select "a[href='#{transaction_path(wanted)}']"
    end
  end

  test "filters combine and exports use the same split rows and sort" do
    original = entry(amount: 40)
    original.replace_splits!([{ name: "Gas", amount: "25", category_id: @category.id }, { name: "Toll", amount: "15", category_id: @parent.id }])
    entry(name: "Refund", amount: -25)
    entry(name: "Other currency", iso_currency_code: "CAD")
    filters = { category_id: @parent.id, flow: "outflow", min_amount: "20", max_amount: "30", currency: "USD", from: Date.current.iso8601, to: Date.current.iso8601, sort: "amount", direction: "asc" }
    get transactions_path, params: filters
    assert_response :success
    assert_select 'tbody tr', count: 1
    assert_select 'tbody', text: /Gas/
    get transactions_path(format: :csv), params: filters
    assert_response :success
    rows = CSV.parse(response.body, headers: true)
    assert_equal ["Gas"], rows.map { |row| row["Description"] }
    get trends_path, params: filters
    assert_response :success
    assert_select '.metric', text: /Spending.*25.00/
  end

  test "invalid ranges are actionable and private categories cannot be queried" do
    get transactions_path, params: { from: "bad-date", min_amount: "NaN" }
    assert_response :unprocessable_entity
    assert_select '[role=alert]', text: /valid date/
    get transactions_path(format: :csv), params: { from: "2026-10-23", to: "2026-01-01" }
    assert_response :unprocessable_entity
    other = User.create!(email: "private-search@example.com", password: "test-password")
    category = other.categories.create!(name: "Private")
    get transactions_path, params: { category_id: category.id }
    assert_response :unprocessable_entity
    assert_select '[role=alert]', text: /available category/
  end

  test "pagination is stable and includes records beyond the old limit" do
    28.times { |index| entry(name: "Purchase #{index}", amount: index + 1) }
    get transactions_path, params: { sort: "amount", direction: "asc", per_page: 25, page: 2 }
    assert_response :success
    assert_select 'tbody tr', count: 3
    assert_select '.table-caption', text: /28 matching transactions/
    assert_select 'nav[aria-label="Transaction pages"] a', text: 'Previous'
    get transactions_path(format: :csv), params: { sort: "amount", direction: "asc", page: 2, per_page: 25 }
    rows = CSV.parse(response.body, headers: true)
    assert_equal 28, rows.size
    assert_equal (1..28).map(&:to_d), rows.map { |row| row['Amount'].to_d }
  end

  test "exact tags avoid substring matches and inherited split exclusions remain searchable" do
    original = entry(tags: "work", hidden: true)
    original.replace_splits!([{ name: "First", amount: "10" }, { name: "Second", amount: "15" }])
    entry(tags: "homework")
    get transactions_path, params: { tag: "WORK", flag: "hidden" }
    assert_response :success
    assert_select 'tbody tr', count: 2
    get transactions_path, params: { tag: "work", reportable: "1" }
    assert_select 'tbody tr', count: 1
    assert_select '.empty-state', text: /No matching transactions/
  end

  test "management searches retain full category choices for merging" do
    get categories_path, params: { q: "Fuel" }
    assert_response :success
    assert_select '.category-management', count: 1
    get edit_category_path(@category)
    assert_response :success
    assert_select 'select[name=target_id] option', text: 'Transport'
    @user.manual_assets.create!(name: "Home", notes: "Oak street", asset_type: "property", value: 100, valued_on: Date.current, currency: "USD")
    get manual_assets_path, params: { q: "oak", kind: "property" }
    assert_select 'tbody tr', text: /Home/
    @user.transaction_rules.create!(match_text: "Fuel station", category: @category, kind: "regular")
    get transaction_rules_path, params: { q: "fuel", kind: "regular" }
    assert_response :success
    assert_select '.category-management', count: 1
  end

  test "transaction filters expose removable context without hiding search" do
    get transactions_path, params: { q: 'Fuel', category_id: @category.id, source: 'manual' }
    assert_response :success
    assert_select '.search-toolbar input[name=q][value=Fuel]'
    assert_select '.filter-panel:not([open])'
    assert_select '.active-filters a[aria-label="Remove filter: Search: Fuel"]'
    assert_select '.active-filters a', text: /Category: Transport > Fuel/
    get transactions_path, params: { from: 'invalid' }
    assert_select '.filter-panel[open]'
  end

  test "bulk edits require selected owned transactions and an explicit change" do
    wanted = entry
    other = User.create!(email: 'bulk-private@example.com', password: 'test-password')
    private_entry = other.transactions.create!(name: 'Private', date: Date.current, amount: 10, source: 'manual', iso_currency_code: 'USD')
    patch bulk_update_transactions_path, params: { bulk: { hidden: '1' } }
    assert_redirected_to transactions_path
    assert_match(/Select at least one/, flash[:alert])
    patch bulk_update_transactions_path, params: { ids: [wanted.id], bulk: { tags: '', hidden: '' } }
    assert_match(/Choose at least one change/, flash[:alert])
    assert_not wanted.reload.hidden?
    patch bulk_update_transactions_path, params: { ids: [wanted.id, wanted.id, private_entry.id], bulk: { hidden: '1' }, return_filters: { q: 'Fuel', host: 'example.com' } }
    assert_redirected_to transactions_path(q: 'Fuel')
    assert_equal '1 transaction updated.', flash[:notice]
    assert wanted.reload.hidden?
    assert_not private_entry.reload.hidden?
  end

  test "budget search and status filters use the selected month and keep creation options" do
    @user.budgets.create!(category: @category, amount: 10, currency: "USD", starts_on: Date.current.beginning_of_month)
    entry(amount: 25)
    get budgets_path, params: { q: "fuel", status: "over", currency: "USD", month: Date.current.strftime('%Y-%m') }
    assert_response :success
    assert_select '.budget-grid h2', text: 'Transport > Fuel'
    get budgets_path, params: { status: "within" }
    assert_response :success
    assert_select '.budget-grid h2', count: 0
    assert_select 'select[name="budget[category_id]"] option', text: 'Transport'
  end
end
