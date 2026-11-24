require "digest"

module Imports
  class TillerWorkbook
    def self.read(io)
      XlsxReader.open(io) { |reader| new(reader).data }
    end

    attr_reader :data

    def initialize(reader)
      @reader = reader
      @data = { "transactions" => [], "accounts" => [], "balances" => [], "categories" => [], "rules" => [], "warnings" => [], "errors" => [] }
      @accounts = {}
      read_categories
      read_accounts
      read_balances
      read_transactions
      read_rules
      @data["accounts"] = @accounts.values.sort_by { |account| [account["institution"], account["name"]] }
      @data["warnings"] << "Workbook charts and calculated report tabs are rebuilt from imported history in Worth."
      @data["warnings"] << "Choose the workbook currency below; Tiller does not provide a currency column in this template."
    end

    private

    def read_categories
      return unless @reader.sheet_names.include?("Categories")
      rows = @reader.table("Categories", required: ["Category", "Group", "Type"])
      rows.each do |row|
        next if row["Category"].blank?
        @data["categories"] << { "name" => row["Category"], "group" => row["Group"], "type" => row["Type"], "hidden" => hidden?(row["Hide From Reports"]) }
      end
      if @data["categories"].map { |row| row["name"] }.uniq.size != @data["categories"].size
        @data["errors"] << "Categories contains repeated category names. Give each category a unique name before importing."
      end
      budget_values = rows.flat_map { |row| row.select { |key, _| key.match?(/\A\d+(\.0+)?\z/) }.values }
      @data["warnings"] << if budget_values.any? { |value| value.present? && decimal(value) != 0 }
        "Monthly budget amounts need manual setup in Worth. They are not imported because Worth currently uses a single recurring amount per category."
      else
        "No nonzero monthly budgets were found. No budgets will be created."
      end
    end

    def read_accounts
      return unless @reader.sheet_names.include?("Accounts")
      rows = @reader.table("Accounts", required: ["Unique Account Identifier", "Account Id"])
      # A:D is a separate settings table. Its rows do not necessarily line up with F:Q.
      overrides = rows.select { |row| row["Account"].present? }.index_by { |row| row["Account"] }
      rows.each do |row|
        next if row["Account Id"].blank?
        override = overrides[row["Unique Account Identifier"]] || {}
        account = source_account(row["Account Id"], row["Account 2"].presence || row["Unique Account Identifier"], row["Institution"], row["Account #"])
        account.merge!("class" => override["Class Override"].presence || row["Class"].presence || row["Class (BH)"],
          "type" => row["Type"], "group" => override["Group"].presence || row["Group 2"],
          "hidden" => hidden?(override["Hide"].presence || row["Hide 2"]))
      end
    end

    def read_balances
      return unless @reader.sheet_names.include?("Balance History")
      rows = @reader.table("Balance History", required: ["Date", "Account", "Account ID", "Balance", "Class"])
      rows.each do |row|
        with_row("Balance History", row) do
          raise ArgumentError, "Account ID is required" if row["Account ID"].blank?
          timestamp = excel_number(row["Date"])
          date = date_value(row["Date"])
          # Some exports have a date-only Date cell and the time in a separate column.
          timestamp += BigDecimal(row["Time"]) % 1 if timestamp.frac.zero? && row["Time"].present?
          account = source_account(row["Account ID"], row["Account"], row["Institution"], row["Account #"])
          if !account["latest_at"] || timestamp > BigDecimal(account["latest_at"])
            account["class"] = row["Class"] if account["class"].blank?
            account["type"] = row["Type"] if account["type"].blank?
            account["latest_at"] = timestamp.to_s("F")
          end
          raise ArgumentError, "Class must be Asset or Liability" unless %w[Asset Liability].include?(account["class"])
          @data["balances"] << { "account_key" => account["key"], "date" => date.iso8601, "timestamp" => timestamp.to_s("F"), "balance" => decimal(row["Balance"]).to_s("F"), "id" => row["Balance ID"], "row" => row["_row"] }
        end
      end
    end

    def read_transactions
      rows = @reader.table("Transactions", required: ["Date", "Description", "Amount", "Account"])
      occurrences = Hash.new(0)
      ids = rows.map { |row| row["Transaction ID"] }.reject(&:blank?).tally
      categories = @data["categories"].index_by { |category| category["name"] }
      missing_ids = 0
      rows.each do |row|
        with_row("Transactions", row) do
          raise ArgumentError, "Description is required" if row["Description"].blank?
          date = date_value(row["Date"])
          amount = -decimal(row["Amount"])
          account = source_account(row["Account ID"], row["Account"], row["Institution"], row["Account #"])
          category = categories[row["Category"]]
          if row["Category"].present? && !category
            category = { "name" => row["Category"], "group" => "", "type" => "", "hidden" => false }
            @data["categories"] << category
            categories[category["name"]] = category
          end
          fingerprint = Digest::SHA256.hexdigest([date, row["Description"], amount.to_s("F"), account["key"]].to_json)
          id = row["Transaction ID"]
          missing_ids += 1 if id.blank?
          # An ID may be reused by split rows. Always use the financial fingerprint
          # so importing a subset or reordering an export keeps the same identity.
          # Description/category edits do not change an ID-bearing row's identity.
          identity = id.present? ? "id:#{id}" : "row:#{fingerprint}"
          identity += ":#{Digest::SHA256.hexdigest([date, amount.to_s('F'), account['key']].to_json)}" if id.present?
          occurrences[identity] += 1
          source_id = "tiller:#{identity}:#{occurrences[identity]}"
          @data["transactions"] << { "row" => row["_row"], "date" => date.iso8601, "name" => row["Description"], "amount" => amount.to_s("F"),
            "account_key" => account["key"], "source_account_name" => row["Account"], "category" => row["Category"],
            "source_transaction_id" => source_id, "original_description" => row["Full Description"], "notes" => row["Notes"], "tags" => row["Tags"],
            "hidden" => category&.fetch("hidden", false) || false, "transfer" => category&.fetch("type", "") == "Transfer",
            "file_duplicate" => occurrences[identity] > 1,
            "metadata" => row.except("_row").reject { |_, value| value.blank? } }
        end
      end
      @data["warnings"] << "#{missing_ids} older #{missing_ids == 1 ? 'transaction has' : 'transactions have'} no Tiller ID. Worth will recognize unchanged rows when you import the same data again." if missing_ids.positive?
      @data["warnings"] << "#{ids.count { |_, count| count > 1 }} Tiller transaction IDs are reused. Distinct rows are retained and identical repeats are flagged for review." if ids.values.any? { |count| count > 1 }
    end

    def read_rules
      return unless @reader.sheet_names.include?("AutoCat")
      @data["rules"] = @reader.table("AutoCat", required: ["Category", "Description Contains"])
      @data["warnings"] << "AutoCat rules (#{@data['rules'].size}) are retained for reference, but are not activated. Worth's rule conditions and ordering differ; recreate rules in Rules after import."
    end

    def source_account(id, name, institution, mask)
      key = id.presence || "legacy:#{Digest::SHA256.hexdigest([name, institution, mask].to_json)}"
      @accounts[key] ||= { "key" => key, "name" => name.presence || "Imported account", "institution" => institution.to_s, "mask" => mask.to_s, "hidden" => false }
    end

    def with_row(sheet, row)
      yield
    rescue ArgumentError => e
      @data["errors"] << "#{sheet} row #{row['_row']}: #{e.message}"
    end

    def hidden?(value)
      %w[hide hidden true yes 1].include?(value.to_s.downcase)
    end

    def decimal(value)
      raw = value.to_s.delete(",$ ")
      raw = "-#{raw[1..-2]}" if raw.start_with?("(") && raw.end_with?(")")
      raise ArgumentError, "Invalid numeric value" unless raw.match?(/\A[+-]?\d+(?:\.\d+)?\z/)
      result = BigDecimal(raw)
      raise ArgumentError, "Amount exceeds Worth's supported range or precision" if result.abs >= 10**15 || result.round(4) != result
      result
    end

    def excel_number(value)
      raw = value.to_s
      if raw.match?(/\A\d+(?:\.\d+)?\z/)
        BigDecimal(raw)
      else
        BigDecimal((date_value(raw) - @reader.date_epoch).to_i.to_s)
      end
    end

    def date_value(value)
      raw = value.to_s
      date = if raw.match?(/\A\d+(?:\.\d+)?\z/)
        @reader.date_epoch + BigDecimal(raw).floor
      elsif raw.match?(/\A\d{1,2}\/\d{1,2}\/\d{4}\z/)
        Date.strptime(raw, "%m/%d/%Y")
      else
        Date.iso8601(raw)
      end
      raise ArgumentError, "Date must be between 1900 and today" unless (Date.new(1900, 1, 1)..Date.current).cover?(date)
      date
    rescue Date::Error
      raise ArgumentError, "Invalid date"
    end
  end
end
