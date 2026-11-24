module Imports
  class MintCsvTransactions
    Result = Struct.new(:inserted, :skipped, :errors, keyword_init: true)
    def self.call(user:, io:, account: nil)
      batch = user.import_batches.create!(csv_text: io.read)
      preview = CsvPreview.new(batch)
      errors = preview.rows.filter_map { |row| { row: row[:number], error: row[:error] } if row[:error] }
      return Result.new(inserted: 0, skipped: 0, errors: errors) if errors.any?
      inserted = preview.commit!
      Result.new(inserted: inserted, skipped: preview.rows.size - inserted, errors: [])
    end
  end
end
