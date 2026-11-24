require "test_helper"
require_relative "../support/tiller_workbook_fixture"

class TillerImportsTest < ActionDispatch::IntegrationTest
  include TillerWorkbookFixture
  self.fixture_table_names = []

  setup do
    @user = User.create!(email: 'tiller-import@example.com', password: 'test-password')
    post sign_in_path, params: { email: @user.email, password: 'test-password' }
  end

  def batch(sheets = tiller_sheets, **settings)
    data = Imports::TillerWorkbook.read(xlsx(sheets))
    @user.import_batches.create!(csv_text: data.to_json, settings: { format: 'tiller', currency: 'USD', include_duplicates: '1' }.merge(settings))
  end

  test "whole workbook upload stages a bounded preview and commits only on confirmation" do
    Tempfile.create(['worth-tiller', '.xlsx']) do |file|
      file.binmode
      file.write(xlsx(tiller_sheets).read)
      file.flush
      assert_no_difference ['Transaction.count', 'Account.count', 'BalanceSnapshot.count', 'Category.count', 'PlaidItem.count'] do
        post imports_path, params: { file: Rack::Test::UploadedFile.new(file.path, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') }
      end
      import = @user.import_batches.last
      assert_redirected_to import_path(import)
      follow_redirect!
      assert_response :success
      assert_select 'h2', text: 'Match your accounts'
      assert_select 'td', text: /Market/
      assert_select 'input[type=submit][name=commit_import]'
      assert_no_difference ['PlaidItem.count', 'TransactionRule.count', 'Budget.count'] do
        patch import_path(import), params: { currency: 'USD', include_duplicates: '1', commit_import: 'Confirm workbook import' }
      end
      assert_redirected_to import_path(import)
      follow_redirect!
      assert_response :success
      assert_select 'h1', text: 'Import complete'
      assert_equal 4, @user.transactions.count
      assert_equal 3, @user.balance_snapshots.count
      assert_equal 2, @user.accounts.count
      assert_equal 1, import.reload.settings['autocat_reference'].size
      assert_equal 'Imported (source file cleared)', import.csv_text
      assert_equal 'Living', @user.transactions.find_by(name: 'Market').category.parent.name
      assert_equal 150.to_d, @user.accounts.find_by(import_source_key: 'tiller:checking').current_balance
      debt = @user.accounts.find_by(import_source_key: 'tiller:debt')
      assert_equal 'loan', debt.account_type
      assert debt.net_worth_excluded?
      assert_nil @user.transactions.find_by(name: 'Old store').account_id
      history = FinancialReport.net_worth_history(@user, currency: 'USD', from: Date.new(2026, 1, 1), to: Date.new(2026, 1, 31))
      assert_equal [110.to_d, 150.to_d], history.map { |row| row[1] }
      assert_equal 35.5.to_d, @user.transactions.reportable.where('amount > 0').sum(:amount)
      [root_path, transactions_path, trends_path, categories_path].each do |path|
        get path
        assert_response :success
      end
    end
  end

  test "exact reimports preserve edits and do not duplicate any records" do
    Imports::TillerPreview.new(batch).commit!
    original = @user.transactions.find_by(name: 'Market')
    original.update!(name: 'My market note', notes: 'Keep my edits')
    again = batch
    assert_no_difference ['Transaction.count', 'Account.count', 'BalanceSnapshot.count', 'Category.count'] do
      assert_equal 0, Imports::TillerPreview.new(again).commit!['transactions']
    end
    assert_equal 'Keep my edits', original.reload.notes
    assert_raises(ArgumentError) { Imports::TillerPreview.new(batch).tap { |preview| preview.commit!; preview.commit! } }
  end

  test "invalid rows and foreign account mappings roll back the entire import" do
    bad = tiller_sheets
    bad['Transactions'] << [nil, 'bad', 'Bad row', nil, -5, 'Checking']
    assert_no_difference ['Transaction.count', 'Account.count', 'BalanceSnapshot.count', 'Category.count'] do
      assert_raises(ArgumentError) { Imports::TillerPreview.new(batch(bad)).commit! }
    end
    other = User.create!(email: 'other-tiller@example.com', password: 'test-password')
    foreign = other.accounts.create!(name: 'Private', account_type: 'depository', import_source_key: 'tiller:private', iso_currency_code: 'USD')
    import = batch(accounts: { debt: foreign.id.to_s })
    assert_no_difference ['Transaction.count', 'Account.count', 'BalanceSnapshot.count', 'Category.count'] do
      assert_raises(ArgumentError) { Imports::TillerPreview.new(import).commit! }
    end
    assert_nil import.reload.imported_at
  end

  test "mapped linked accounts retain current balances and existing daily observations" do
    institution = Institution.create!(name: 'Test', plaid_institution_id: 'test-tiller-institution')
    item = @user.plaid_items.create!(institution: institution, plaid_item_id: 'test-tiller-item', access_token: 'test-token')
    account = @user.accounts.create!(plaid_item: item, plaid_account_id: 'test-tiller-account', name: 'Live Checking', account_type: 'depository', iso_currency_code: 'USD', current_balance: 999)
    snapshot = @user.balance_snapshots.create!(account: account, as_of_date: Date.new(2026, 1, 2), current_balance: 123, iso_currency_code: 'USD')
    import = batch(accounts: { checking: account.id.to_s, debt: 'transactions_only' })
    assert_no_difference ['Account.count', 'PlaidItem.count'] do
      Imports::TillerPreview.new(import).commit!
    end
    assert_equal 999.to_d, account.reload.current_balance
    assert_equal 123.to_d, snapshot.reload.current_balance
    assert_equal account, @user.transactions.find_by(name: 'Market').account
    assert_equal 2, account.balance_snapshots.count
    assert_equal account.id.to_s, Imports::TillerPreview.new(batch).account_selection({ 'key' => 'checking' })
  end

  test "duplicates with posting lag and repeated source rows are flagged and can be skipped" do
    @user.transactions.create!(source: 'plaid', name: 'Market', date: Date.new(2026, 1, 10), amount: 25.50, iso_currency_code: 'USD')
    sheets = tiller_sheets
    sheets['Transactions'] << sheets['Transactions'][1].dup
    import = batch(sheets)
    preview = Imports::TillerPreview.new(import)
    assert_equal 2, preview.summary['duplicates']
    result = preview.commit!
    assert_equal 5, result['transactions']
    assert_equal 2, @user.transactions.where(source: 'import', duplicate: true).count
    assert_equal 35.5.to_d, @user.transactions.reportable.where('amount > 0').sum(:amount)
  end

  test "currency and classification mismatches block account mapping" do
    account = @user.accounts.create!(name: 'CAD Checking', account_type: 'depository', import_source_key: 'local:cad', iso_currency_code: 'CAD')
    assert_match(/different currency/, assert_raises(ArgumentError) { Imports::TillerPreview.new(batch(accounts: { checking: account.id.to_s })).commit! }.message)
    account.update!(iso_currency_code: 'USD', account_type: 'loan')
    assert_match(/different asset\/liability/, assert_raises(ArgumentError) { Imports::TillerPreview.new(batch(accounts: { checking: account.id.to_s })).commit! }.message)
  end

  test "partial exports of reused IDs remain idempotent and changed financial rows are skipped" do
    sheets = tiller_sheets
    sheets['Transactions'] << sheets['Transactions'][1].dup
    Imports::TillerPreview.new(batch(sheets)).commit!
    partial = tiller_sheets
    partial['Transactions'] = partial['Transactions'].first(2)
    preview = Imports::TillerPreview.new(batch(partial))
    assert_equal 1, preview.summary['already_imported']
    assert_equal 0, preview.commit!['transactions']
    partial['Transactions'][1][4] = -30
    changed = Imports::TillerPreview.new(batch(partial))
    assert_equal 1, changed.summary['changed_transactions']
    assert_equal 0, changed.summary['duplicates']
    assert_no_difference 'Transaction.count' do
      result = changed.commit!
      assert_equal 0, result['transactions']
      assert_equal 1, result['changed_transactions']
    end
  end

  test "duplicate skip choice imports remaining rows and source exclusions survive automatic classification" do
    sheets = tiller_sheets
    sheets['Transactions'] << sheets['Transactions'][1].dup
    preview = Imports::TillerPreview.new(batch(sheets, include_duplicates: '0'))
    result = preview.commit!
    assert_equal 4, result['transactions']
    assert_equal 1, result['skipped']
    assert_equal 0, @user.transactions.where(duplicate: true).count
    CashFlowClassifier.call(user: @user)
    AutoCategorizer.call(user: @user)
    imported = @user.transactions.find_by(name: 'Investing')
    assert imported.hidden?
    assert imported.transfer?
    assert_equal 'Investment move', imported.category.name
  end

  def linked_account(name: 'Live Checking', mask: '1234', institution: 'Bank', currency: 'USD')
    bank = Institution.find_or_create_by!(plaid_institution_id: "bank-#{institution}") { |record| record.name = institution }
    item = @user.plaid_items.create!(institution: bank, plaid_item_id: "item-#{SecureRandom.hex(6)}", access_token: 'test-token')
    @user.accounts.create!(plaid_item: item, plaid_account_id: "account-#{SecureRandom.hex(6)}", name: name, mask: mask, account_type: 'depository', iso_currency_code: currency, current_balance: 999)
  end

  def property_sheets(observations = [[46024, 250_000]])
    {
      'Transactions' => [['Date', 'Description', 'Amount', 'Account']],
      'Balance History' => [['Date', 'Account', 'Account ID', 'Balance', 'Class', 'Type']] + observations.map { |date, value| [date, 'Home', 'manual:home', value, 'Asset', 'OTHER'] }
    }
  end

  test "updated export adds only new rows and dates while keeping edits and renamed categories" do
    original = batch
    Imports::TillerPreview.new(original).commit!
    transaction = @user.transactions.find_by!(name: 'Market')
    transaction.update!(name: 'My edited market', amount: 27, notes: 'Keep this', category_locked: true)
    category = transaction.category
    category.update!(name: 'Food at home')
    snapshot = @user.balance_snapshots.find_by!(account: transaction.account, as_of_date: Date.new(2026, 1, 2))
    snapshot.update!(current_balance: 125)
    original_transaction_attributes = transaction.reload.attributes
    original_snapshot_attributes = snapshot.reload.attributes
    sheets = tiller_sheets
    sheets['Transactions'][1][2] = 'Edited in Tiller too'
    sheets['Transactions'] << [nil, 46028, 'New market', 'Groceries', -12, 'Checking', 'xxxx1234', 'Bank', 'tx-new', 'checking']
    sheets['Transactions'] << [nil, 46028, 'New cash purchase', 'Old category', -8, 'Old cash']
    sheets['Transactions'] = [sheets['Transactions'].first] + sheets['Transactions'].drop(1).reverse
    sheets['Balance History'][2][8] = 111 # Existing date changed in source; Worth's edit wins.
    sheets['Balance History'] << [nil, 46028.8, 0.8, 'Checking', 'xxxx1234', 'checking', 'b-new', 'Bank', 200, 'CHECKING', 'Asset']
    updated = batch(sheets)
    preview = Imports::TillerPreview.new(updated)
    assert_equal 4, preview.summary['already_imported']
    assert_equal 2, preview.summary['ready']
    assert_equal 1, preview.summary['new_balances']
    assert_equal 3, preview.summary['existing_daily_balances_preserved']
    assert_no_difference ['Account.count', 'Category.count'] do
      result = preview.commit!
      assert_equal 2, result['transactions']
      assert_equal 1, result['balances']
    end
    assert_equal category, @user.transactions.find_by!(name: 'New market').category
    assert_equal original_transaction_attributes, transaction.reload.attributes
    assert_equal original_snapshot_attributes, snapshot.reload.attributes
    assert_equal 200.to_d, transaction.account.reload.current_balance
    saved_accounts = @user.accounts.order(:id).map(&:attributes)
    assert_no_difference ['Transaction.count', 'BalanceSnapshot.count', 'Category.count', 'Account.count'] do
      result = Imports::TillerPreview.new(batch(sheets)).commit!
      assert_equal 0, result['transactions']
      assert_equal 0, result['balances']
    end
    assert_equal saved_accounts, @user.accounts.order(:id).map(&:attributes)
  end

  test "safe bank matches are suggested, ambiguous matches are not, and receipts remember choices" do
    account = linked_account
    import = batch
    preview = Imports::TillerPreview.new(import)
    source = preview.data['accounts'].find { |row| row['key'] == 'checking' }
    assert_equal account.id.to_s, preview.account_selection(source)
    assert_match(/matching bank/, preview.account_mapping.explanation(source))
    preview.commit!
    assert_equal account.id.to_s, import.reload.settings['accounts']['checking']
    assert_equal 999.to_d, account.reload.current_balance
    account.update!(name: 'Renamed bank account', mask: '9999')
    assert_equal account.id.to_s, Imports::TillerPreview.new(batch).account_selection(source)
    # A separate source with two possible bank matches is left for the user.
    linked_account(mask: '5678')
    linked_account(mask: '5678')
    unmapped = { 'key' => 'another', 'name' => 'Checking', 'mask' => 'xxxx5678', 'institution' => 'Bank', 'class' => 'Asset', 'latest_at' => '46024' }
    assert_equal 'new', Imports::TillerAccountMapping.new(batch, currency: 'USD').selection(unmapped)
  end

  test "same mapped account date and amount catches bank descriptions that differ" do
    account = linked_account
    @user.transactions.create!(source: 'plaid', account: account, name: 'PAYMENT', date: Date.new(2026, 1, 2), amount: 25.50, iso_currency_code: 'USD')
    import = batch
    preview = Imports::TillerPreview.new(import)
    assert_equal 1, preview.summary['duplicates']
    assert_match(/same account, date and amount/, preview.rows.first[:reason])
    get import_path(import, review: 'duplicates')
    assert_response :success
    assert_select 'small', text: /same account, date and amount/
    result = preview.commit!
    assert_equal 1, result['duplicates']
    imported = @user.transactions.find_by!(source: 'import', name: 'Market')
    assert imported.duplicate?
    get transaction_path(imported)
    assert_select '.flash-alert', text: /Flagged during import:.*same account, date and amount/
  end

  test "different bank descriptions do not match other accounts dates or signs" do
    account = linked_account
    other = linked_account(mask: '0000')
    [[other, Date.new(2026, 1, 2), 25.50], [account, Date.new(2026, 1, 3), 25.50], [account, Date.new(2026, 1, 2), -25.50]].each do |bank, date, amount|
      @user.transactions.create!(source: 'plaid', account: bank, name: 'PAYMENT', date: date, amount: amount, iso_currency_code: 'USD')
    end
    assert_equal 0, Imports::TillerPreview.new(batch).summary['duplicates']
  end

  test "manual assets receive only new valuation dates and keep existing values" do
    home = @user.manual_assets.create!(name: 'Home', asset_type: 'property', currency: 'USD', value: 300_000, valued_on: Date.new(2026, 1, 3))
    import = batch(property_sheets([[46024, 250_000], [46025, 299_000]]))
    preview = Imports::TillerPreview.new(import)
    assert_equal "asset:#{home.id}", preview.account_selection(preview.data['accounts'].first)
    assert_equal 1, preview.summary['new_asset_valuations']
    assert_equal 1, preview.summary['existing_asset_valuations_preserved']
    assert_no_difference ['Account.count', 'ManualAsset.count', 'BalanceSnapshot.count'] do
      patch import_path(import), params: { currency: 'USD', include_duplicates: '1', accounts: { 'manual:home' => "asset:#{home.id}" }, commit_import: 'Confirm' }
    end
    follow_redirect!
    assert_response :success
    assert_select 'p', text: /1 new asset valuation\./
    assert_equal 300_000.to_d, home.reload.value
    assert_equal 300_000.to_d, home.asset_valuations.find_by!(valued_on: Date.new(2026, 1, 3)).value
    home.update!(name: 'Renamed home')
    updated = batch(property_sheets([[46024, 240_000], [46025, 299_000], [46026, 310_000]]))
    preview = Imports::TillerPreview.new(updated)
    assert_equal "asset:#{home.id}", preview.account_selection(preview.data['accounts'].first)
    result = preview.commit!
    assert_equal 1, result['asset_valuations']
    assert_equal 2, result['existing_asset_valuations_preserved']
    assert_equal 310_000.to_d, home.reload.value
    assert_equal Date.new(2026, 1, 4), home.valued_on
    assert_equal 250_000.to_d, home.asset_valuations.find_by!(valued_on: Date.new(2026, 1, 2)).value
    assert_no_difference ['AssetValuation.count', 'Account.count'] do
      assert_equal 0, Imports::TillerPreview.new(batch(property_sheets([[46024, 250_000], [46026, 310_000]]))).commit!['asset_valuations']
    end
  end

  test "first assisted import's manual asset mapping is reused without recreating the home" do
    home = @user.manual_assets.create!(name: 'Home', asset_type: 'property', currency: 'USD', value: 300_000, valued_on: Date.new(2026, 1, 3))
    @user.import_batches.create!(csv_text: 'Imported (source file cleared)', imported_at: Time.current, settings: { format: 'tiller', currency: 'USD', accounts: { 'manual:home' => 'transactions_only' }, manual_asset_mapping: { 'manual:home' => home.id.to_s } })
    home.update!(name: 'Renamed home')
    preview = Imports::TillerPreview.new(batch(property_sheets))
    assert_equal "asset:#{home.id}", preview.account_selection(preview.data['accounts'].first)
    assert_no_difference 'Account.count' do
      assert_equal 1, preview.commit!['asset_valuations']
    end
  end

  test "foreign assets wrong currencies liabilities and invalid precision cannot receive valuations" do
    other = User.create!(email: 'foreign-asset@example.com', password: 'test-password')
    foreign = other.manual_assets.create!(name: 'Home', asset_type: 'property', currency: 'USD', value: 1, valued_on: Date.current)
    local = @user.manual_assets.create!(name: 'Local home', asset_type: 'property', currency: 'CAD', value: 1, valued_on: Date.current)
    [foreign, local].each do |asset|
      assert_no_difference ['AssetValuation.count', 'Account.count'] do
        assert_raises(ArgumentError) { Imports::TillerPreview.new(batch(property_sheets, accounts: { 'manual:home' => "asset:#{asset.id}" })).commit! }
      end
    end
    local.update!(currency: 'USD')
    invalid = property_sheets([[46024, -1]])
    assert_raises(ArgumentError) { Imports::TillerPreview.new(batch(invalid, accounts: { 'manual:home' => "asset:#{local.id}" })).commit! }
    assert_raises(ArgumentError) { Imports::TillerPreview.new(batch(property_sheets([[46024, 1.234]]), accounts: { 'manual:home' => "asset:#{local.id}" })).commit! }
    invalid['Balance History'][1][4] = 'Liability'
    assert_raises(ArgumentError) { Imports::TillerPreview.new(batch(invalid, accounts: { 'manual:home' => "asset:#{local.id}" })).commit! }
  end

  test "transactions-only choices persist and summaries expose skipped balances" do
    import = batch(accounts: { checking: 'transactions_only', debt: 'transactions_only' })
    preview = Imports::TillerPreview.new(import)
    assert_equal 3, preview.summary['skipped_balances']
    result = preview.commit!
    assert_equal 3, result['skipped_balances']
    assert_equal 0, result['balances']
    again = Imports::TillerPreview.new(batch)
    assert_equal 'transactions_only', again.account_selection({ 'key' => 'checking' })
    assert_equal 3, again.summary['skipped_balances']
  end

  test "a preview created before another import rechecks IDs when committed" do
    first = Imports::TillerPreview.new(batch)
    second = Imports::TillerPreview.new(batch(accounts: { checking: 'new', debt: 'new' }))
    first.commit!
    assert_no_difference ['Transaction.count', 'Account.count', 'BalanceSnapshot.count', 'Category.count'] do
      result = second.commit!
      assert_equal 0, result['transactions']
      assert_equal 4, result['already_imported']
      assert_equal 3, result['existing_daily_balances_preserved']
    end
  end

  test "reimports cannot change the currency of imported history" do
    Imports::TillerPreview.new(batch(accounts: { checking: 'transactions_only', debt: 'transactions_only' })).commit!
    preview = Imports::TillerPreview.new(batch(currency: 'CAD'))
    assert_match(/currency differs/, preview.errors.join)
    assert_raises(ArgumentError) { preview.commit! }
  end

  test "recent receipts and changed source rows can be reviewed without losing existing data" do
    Imports::TillerPreview.new(batch).commit!
    sheets = tiller_sheets
    sheets['Transactions'][1][4] = -30
    changed = batch(sheets)
    get import_path(changed, review: 'changes')
    assert_response :success
    assert_select 'td', text: /Source changed/
    assert_select 'tbody tr', minimum: 1
    Imports::TillerPreview.new(changed).commit!
    get import_path(changed)
    assert_response :success
    assert_select 'summary', text: /Review changed source rows/
    get new_import_path
    assert_response :success
    assert_select 'h2', text: 'Recent workbook imports'
    assert_select "a[href='#{import_path(changed)}']"
  end
end
