require "zip"
require "cgi"

module TillerWorkbookFixture
  def xlsx(sheets, date1904: false)
    output = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("xl/workbook.xml")
      zip.write('<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><workbookPr date1904="' + (date1904 ? '1' : '0') + '"/><sheets>')
      sheets.keys.each_with_index { |name, i| zip.write("<sheet name=\"#{CGI.escapeHTML(name)}\" r:id=\"r#{i}\"/>") }
      zip.write('</sheets></workbook>')
      zip.put_next_entry("xl/_rels/workbook.xml.rels")
      zip.write('<Relationships>')
      sheets.each_with_index { |_, i| zip.write("<Relationship Id=\"r#{i}\" Target=\"worksheets/sheet#{i}.xml\"/>") }
      zip.write('</Relationships>')
      sheets.each_with_index do |(_, rows), i|
        zip.put_next_entry("xl/worksheets/sheet#{i}.xml")
        zip.write('<worksheet><sheetData>')
        rows.each_with_index do |row, r|
          zip.write("<row r=\"#{r + 1}\">")
          row.each_with_index do |value, c|
            next if value.nil?
            column = ""
            n = c + 1
            while n.positive?
              n, rem = (n - 1).divmod(26)
              column.prepend((65 + rem).chr)
            end
            address = "#{column}#{r + 1}"
            zip.write(if value.is_a?(Hash)
              "<c r=\"#{address}\" t=\"#{value.fetch(:type, 'n')}\"><f>#{CGI.escapeHTML(value.fetch(:formula, '1+1'))}</f>#{value.key?(:value) ? "<v>#{CGI.escapeHTML(value[:value].to_s)}</v>" : ''}</c>"
            elsif value.is_a?(Numeric)
              "<c r=\"#{address}\"><v>#{value}</v></c>"
            else
              "<c r=\"#{address}\" t=\"inlineStr\"><is><t>#{CGI.escapeHTML(value.to_s)}</t></is></c>"
            end)
          end
          zip.write('</row>')
        end
        zip.write('</sheetData></worksheet>')
      end
    end
    StringIO.new(output.string)
  end

  def tiller_sheets
    {
      "Transactions" => [
        [nil, "Date", "Description", "Category", "Amount", "Account", "Account #", "Institution", "Transaction ID", "Account ID", "Full Description", "Notes"],
        [nil, 46024, "Market", "Groceries", -25.50, "Checking", "xxxx1234", "Bank", "tx1", "checking", "Market original", "weekly"],
        [nil, 46025, "Pay", "Salary", 2500, "Checking", "xxxx1234", "Bank", "tx2", "checking"],
        [nil, 46026, "Investing", "Investment move", -100, "Checking", "xxxx1234", "Bank", "tx3", "checking"],
        [nil, 46027, "Old store", "Old category", -10, "Old cash", nil, nil, nil, nil],
      ],
      "Categories" => [
        ["Category", "Group", "Type", "Hide From Reports", 46023],
        ["Groceries", "Living", "Expense", nil, 0],
        ["Salary", "Income", "Income", nil, 0],
        ["Investment move", "Transfers", "Transfer", "Hide", 0],
      ],
      "Accounts" => [
        ["Account", "Class Override", "Group", "Hide", nil, "Unique Account Identifier", "Account Id", "Last Update", "Last Balance", "Account", "Account #", "Institution", "Type", "Class (BH)", "Class", "Group", "Hide"],
        ["Debt unique", "Liability", "Debt group", "Hide", nil, "Checking unique", "checking", 46024, 100, "Checking", "xxxx1234", "Bank", "CHECKING", "Asset", "Asset", "Cash", nil],
        ["Checking unique", "Asset", "Cash group", nil, nil, "Debt unique", "debt", 46024, 50, "Debt", "xxxx5678", "Bank", "MONEY_MARKET", "Asset", "Asset", "Wrong group", nil],
      ],
      "Balance History" => [
        [nil, "Date", "Time", "Account", "Account #", "Account ID", "Balance ID", "Institution", "Balance", "Type", "Class"],
        [nil, 46024.2, 0.2, "Checking", "xxxx1234", "checking", "b1", "Bank", 100, "CHECKING", "Asset"],
        [nil, 46024.8, 0.8, "Checking", "xxxx1234", "checking", "b2", "Bank", 110, "CHECKING", "Asset"],
        [nil, 46025, 0.4, "Checking", "xxxx1234", "checking", "b3", "Bank", 150, "CHECKING", "Asset"],
        [nil, 46024, 0.5, "Debt", "xxxx5678", "debt", "b4", "Bank", 50, "MONEY_MARKET", "Asset"],
      ],
      "AutoCat" => [["Category", "Description Contains", "Amount Min"], ["Groceries", "Market", 10]],
      "Yearly Budget" => [[{ type: "e", value: "#REF!" }]],
    }
  end
end
