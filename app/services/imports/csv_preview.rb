require "csv"
require "digest"
module Imports
  class CsvPreview
    ALIASES = { "date" => ["date", "transaction date", "posted date"], "description" => ["description", "merchant", "payee", "name"],
      "amount" => ["amount"], "category" => ["category", "category name", "categories"], "account" => ["account", "account name"],
      "type" => ["transaction type", "type"], "notes" => ["notes", "memo"] }.freeze
    attr_reader :headers, :rows, :mapping, :source_categories
    def initialize(batch)
      @batch = batch
      table = CSV.parse(batch.csv_text.delete_prefix("\uFEFF"), headers: true)
      @headers = table.headers.compact
      raise ArgumentError, "CSV must have unique, nonblank headers" if headers.empty? || headers.uniq.size != headers.size || table.headers.any?(&:blank?)
      @mapping = ALIASES.transform_values { |names| headers.find { |h| names.include?(h.strip.downcase) } }.merge(batch.settings.fetch("headers", {}))
      %w[date description amount].each { |key| raise ArgumentError, "Map the required #{key} column" unless headers.include?(mapping[key]) }
      @rows = []
      occurrences = Hash.new(0)
      table.each_with_index do |row, index|
        next if row.fields.all?(&:blank?)
        begin
          attrs = attributes(row)
          identity = [attrs[:date], attrs[:name], attrs[:amount].to_s("F"), attrs[:source_account_name], attrs[:iso_currency_code]].join("|")
          occurrences[identity] += 1
          attrs[:source_transaction_id] = Digest::SHA256.hexdigest("#{identity}|#{occurrences[identity]}")
          existing = batch.user.transactions.find_by(source: "import", source_transaction_id: attrs[:source_transaction_id])
          candidates = batch.user.transactions.roots.where(date: attrs[:date], amount: attrs[:amount], iso_currency_code: attrs[:iso_currency_code]).limit(10).to_a
          @rows << { number: index + 2, attrs: attrs, existing: existing, candidates: candidates, file_duplicate: occurrences[identity] > 1 }
        rescue ArgumentError => e
          @rows << { number: index + 2, error: e.message }
        end
      end
      @source_categories = rows.filter_map { |r| r.dig(:attrs, :source_category).presence }.uniq.sort
    end
    def commit!(include_duplicates: [], profile_name: nil)
      count = 0
      @batch.with_lock do
        raise ArgumentError, "This batch was already imported" if @batch.imported_at
        raise ArgumentError, "Fix invalid rows before importing" if rows.any? { |row| row[:error] }
        rows.each do |row|
          next if row[:existing] || @batch.user.transactions.exists?(source: "import", source_transaction_id: row[:attrs][:source_transaction_id])
          duplicate = row[:candidates].any? || row[:file_duplicate]
          next if duplicate && !include_duplicates.map(&:to_s).include?(row[:number].to_s)
          attrs = row[:attrs].except(:source_category).merge(raw_payload: { "import_category" => row[:attrs][:source_category] })
          category_id = @batch.settings.fetch("categories", {})[row[:attrs][:source_category]]
          if category_id.present?
            attrs[:category] = Category.for_user(@batch.user).find(category_id)
            attrs[:category_locked] = true
            attrs[:category_origin] = "import"
            attrs[:category_reason] = "Your CSV category mapping"
          end
          @batch.user.transactions.create!(attrs.merge(source: "import", duplicate: duplicate))
          count += 1
        end
        CashFlowClassifier.call(user: @batch.user)
        AutoCategorizer.call(user: @batch.user)
        @batch.update!(imported_at: Time.current)
        if profile_name.present?
          profile = @batch.user.import_profiles.find_or_initialize_by(name: profile_name)
          profile.update!(settings: @batch.settings.merge("headers" => mapping))
        end
        @batch.update!(csv_text: "Imported (source file cleared)")
      end
      count
    end
    private
    def attributes(row)
      value = ->(key) { row[mapping[key]].to_s.strip if mapping[key].present? }
      raw_date = value.call("date")
      date = if raw_date.to_s.match?(/\A\d{1,2}\/\d{1,2}\/\d{4}\z/)
        Date.strptime(raw_date, "%m/%d/%Y")
      else
        Date.iso8601(raw_date.to_s)
      end
      name = value.call("description")
      raise ArgumentError, "Description is required" if name.blank?
      raw = value.call("amount").to_s.delete(",$ ")
      raw = "-#{raw[1..-2]}" if raw.start_with?("(") && raw.end_with?(")")
      raise ArgumentError, "Invalid amount" unless raw.match?(/\A[+-]?\d+(?:\.\d{1,4})?\z/)
      amount = BigDecimal(raw)
      amount = -amount.abs if value.call("type").to_s.downcase == "credit"
      amount = amount.abs if value.call("type").to_s.downcase == "debit"
      amount = -amount if @batch.settings["reverse_sign"] == "1"
      { date: date, name: name, amount: amount, source_account_name: value.call("account").presence,
        source_category: value.call("category"), notes: value.call("notes"), iso_currency_code: @batch.settings.fetch("currency", "USD") }
    rescue Date::Error
      raise ArgumentError, "Invalid date (use YYYY-MM-DD or MM/DD/YYYY)"
    end
  end
end
