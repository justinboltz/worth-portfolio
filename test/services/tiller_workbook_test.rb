require "test_helper"
require_relative "../support/tiller_workbook_fixture"

class TillerWorkbookTest < ActiveSupport::TestCase
  include TillerWorkbookFixture
  self.fixture_table_names = []

  test "reads sparse columns, signs, dates, old categories, and independent account overrides" do
    data = Imports::TillerWorkbook.read(xlsx(tiller_sheets))
    assert_empty data['errors']
    assert_equal 4, data['transactions'].size
    assert_equal '2026-01-02', data['transactions'][0]['date']
    assert_equal '25.5', data['transactions'][0]['amount']
    assert_equal '-2500.0', data['transactions'][1]['amount']
    assert data['transactions'][2]['hidden']
    assert data['transactions'][2]['transfer']
    assert_equal 'Market original', data['transactions'][0]['original_description']
    assert_equal 'weekly', data['transactions'][0]['notes']
    assert data['categories'].any? { |category| category['name'] == 'Old category' }
    debt = data['accounts'].find { |account| account['key'] == 'debt' }
    assert_equal 'Liability', debt['class']
    assert_equal 'Debt group', debt['group']
    assert debt['hidden']
    assert_equal 1, data['rules'].size
    assert data['warnings'].any? { |warning| warning.include?('not activated') }
  end

  test "supports the Excel 1904 date system and cached formula values" do
    sheets = { 'Transactions' => [['Date', 'Description', 'Amount', 'Account'], [44562, 'Cached', { value: -2 }, 'Cash']] }
    data = Imports::TillerWorkbook.read(xlsx(sheets, date1904: true))
    assert_equal '2026-01-02', data['transactions'][0]['date']
    assert_equal '2.0', data['transactions'][0]['amount']
  end

  test "bad rows block import and report worksheet row numbers" do
    sheets = tiller_sheets
    sheets['Transactions'] << [nil, 'bad date', 'Bad', nil, -2, 'Cash']
    sheets['Transactions'] << [nil, 46024, 'Precision', nil, -0.12345, 'Cash']
    data = Imports::TillerWorkbook.read(xlsx(sheets))
    assert_equal 2, data['errors'].size
    assert_match(/Transactions row 6/, data['errors'].first)
  end

  test "missing sheets, uncached formulas and source errors are rejected" do
    assert_raises(ArgumentError) { Imports::TillerWorkbook.read(xlsx('Other' => [['Hi']])) }
    sheets = { 'Transactions' => [['Date', 'Description', 'Amount', 'Account'], [46024, 'Bad', { formula: '1+1' }, 'Cash']] }
    assert_match(/no saved formula result/, assert_raises(ArgumentError) { Imports::TillerWorkbook.read(xlsx(sheets)) }.message)
    sheets['Transactions'][1][2] = { type: 'e', value: '#REF!' }
    assert_match(/spreadsheet error/, assert_raises(ArgumentError) { Imports::TillerWorkbook.read(xlsx(sheets)) }.message)
  end

  test "reordered exports keep stable IDs and repeated rows remain visible for review" do
    sheets = tiller_sheets
    sheets['Transactions'] << sheets['Transactions'][1].dup
    original = Imports::TillerWorkbook.read(xlsx(sheets))
    sheets['Transactions'] = [sheets['Transactions'].first] + sheets['Transactions'].drop(1).reverse
    reordered = Imports::TillerWorkbook.read(xlsx(sheets))
    assert_equal original['transactions'].map { |row| row['source_transaction_id'] }.sort, reordered['transactions'].map { |row| row['source_transaction_id'] }.sort
    assert_equal 1, original['transactions'].count { |row| row['file_duplicate'] }
  end

  test "rejects invalid archives" do
    assert_raises(ArgumentError) { Imports::TillerWorkbook.read(StringIO.new('not an xlsx')) }
  end
end
