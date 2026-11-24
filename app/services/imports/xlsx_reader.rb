require "zip"
require "nokogiri"
require "pathname"

module Imports
  # Reads saved cell values only. Workbook formulas, macros, links and instructions
  # are never executed. Nothing from the archive is extracted to the filesystem.
  class XlsxReader
    MAX_BYTES = 25.megabytes
    MAX_EXPANDED_BYTES = 150.megabytes
    MAX_ENTRY_BYTES = 60.megabytes
    MAX_ROWS = 60_000

    def self.open(io)
      bytes = io.read(MAX_BYTES + 1)
      raise ArgumentError, "Use an XLSX workbook under 25 MB" if bytes.bytesize > MAX_BYTES
      result = nil
      Zip::File.open_buffer(bytes) do |archive|
        raise ArgumentError, "Workbook is too large when expanded" if archive.entries.sum(&:size) > MAX_EXPANDED_BYTES || archive.entries.size > 1_000
        result = yield new(archive)
      end
      result
    rescue Zip::Error, Nokogiri::XML::SyntaxError, TypeError
      raise ArgumentError, "This file is not a readable XLSX workbook. Export it as Excel (.xlsx) and try again."
    end

    attr_reader :sheet_names, :date_epoch

    def initialize(archive)
      @archive = archive
      workbook = document("xl/workbook.xml")
      @date_epoch = %w[1 true].include?(workbook.at_xpath("//workbookPr")&.[]("date1904")) ? Date.new(1904, 1, 1) : Date.new(1899, 12, 30)
      relationships = document("xl/_rels/workbook.xml.rels").xpath("//Relationship").index_by { |node| node["Id"] }
      @sheets = workbook.xpath("//sheets/sheet").to_h do |node|
        relation = relationships.fetch(node["id"])
        raise ArgumentError, "External worksheet links are unsupported" if relation["TargetMode"] == "External"
        target = relation["Target"]
        path = Pathname.new(target.start_with?("/") ? target.delete_prefix("/") : "xl/#{target}").cleanpath.to_s
        raise ArgumentError, "Invalid worksheet path" unless path.start_with?("xl/")
        [node["name"], path]
      end
      @sheet_names = @sheets.keys
      @strings = if archive.find_entry("xl/sharedStrings.xml")
        document("xl/sharedStrings.xml").xpath("//si").map { |node| node.xpath(".//t").map(&:text).join }
      else
        []
      end
    rescue KeyError
      raise ArgumentError, "Workbook worksheet references are invalid"
    end

    def table(name, required: [])
      raise ArgumentError, "Workbook is missing the #{name} sheet" unless @sheets.key?(name)
      sheet = document(@sheets.fetch(name))
      rows = sheet.xpath("//sheetData/row")
      raise ArgumentError, "#{name} has too many rows" if rows.size > MAX_ROWS
      headers = nil
      records = []
      rows.each do |row|
        values = {}
        row.xpath("./c").each do |cell|
          column = cell["r"].to_s[/\A[A-Z]+/]
          raise ArgumentError, "Invalid cell address in #{name}" unless column
          values[column] = cell_value(cell, name)
        end
        next if values.values.all?(&:blank?)
        unless headers
          counts = Hash.new(0)
          headers = values.filter_map do |column, value|
            next if value.blank?
            label = value.strip
            counts[label] += 1
            [column, counts[label] == 1 ? label : "#{label} #{counts[label]}"]
          end.to_h
          missing = required - headers.values
          raise ArgumentError, "#{name} is missing columns: #{missing.join(', ')}" if missing.any?
          next
        end
        record = headers.to_h { |column, label| [label, values[column].to_s.strip] }
        records << record.merge("_row" => row["r"].to_i) unless record.except("_row").values.all?(&:blank?)
      end
      raise ArgumentError, "#{name} has no header row" unless headers
      records
    end

    private

    def document(path)
      entry = @archive.find_entry(path)
      raise ArgumentError, "Workbook is missing #{path}" unless entry
      raise ArgumentError, "Workbook XML is too large" if entry.size > MAX_ENTRY_BYTES
      xml = entry.get_input_stream { |stream| stream.read(MAX_ENTRY_BYTES + 1) }
      raise ArgumentError, "Workbook XML is too large" if xml.bytesize > MAX_ENTRY_BYTES
      raise ArgumentError, "Workbook XML must not contain a document type" if xml.include?("<!DOCTYPE")
      Nokogiri::XML(xml) { |config| config.strict.nonet }.remove_namespaces!
    end

    def cell_value(cell, sheet)
      raise ArgumentError, "#{sheet}!#{cell['r']} contains a spreadsheet error. Correct it before importing." if cell["t"] == "e"
      value = cell.at_xpath("./v")&.text
      if cell.at_xpath("./f") && value.nil?
        raise ArgumentError, "#{sheet}!#{cell['r']} has no saved formula result. Recalculate and export the workbook again."
      end
      case cell["t"]
      when "s" then @strings.fetch(Integer(value))
      when "inlineStr" then cell.xpath("./is//t").map(&:text).join
      else value
      end
    rescue IndexError, TypeError
      raise ArgumentError, "Invalid shared text in #{sheet}!#{cell['r']}"
    end
  end
end
