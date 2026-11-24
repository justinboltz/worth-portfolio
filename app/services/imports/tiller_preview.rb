require "set"

module Imports
  class TillerPreview
    CURRENCIES = %w[USD CAD EUR GBP].freeze
    attr_reader :data, :rows, :daily_balances, :currency, :errors, :account_mapping, :balance_rows

    def initialize(batch)
      @batch = batch
      @user = batch.user
      @data = JSON.parse(batch.csv_text)
      @currency = batch.settings.fetch("currency", "USD")
      raise ArgumentError, "Invalid currency" unless CURRENCIES.include?(currency)
      @daily_balances = data.fetch("balances").group_by { |row| [row["account_key"], row["date"]] }.values.map do |observations|
        observations.max_by { |row| [BigDecimal(row["timestamp"]), row["row"]] }
      end
      refresh_preview
    end

    def account_selection(source)
      account_mapping.selection(source)
    end

    def accounts
      account_mapping.accounts
    end

    def manual_assets
      account_mapping.assets
    end

    def balance_summary
      balance_rows.map { |row| row[:status] }.tally
    end

    def summary
      { "transactions" => rows.size, "ready" => rows.count { |row| !row[:existing] && !row[:duplicate] && !row[:conflict] },
        "already_imported" => rows.count { |row| row[:existing] }, "duplicates" => rows.count { |row| !row[:existing] && !row[:conflict] && row[:duplicate] },
        "changed_transactions" => rows.count { |row| row[:conflict] },
        "balance_observations" => data["balances"].size, "daily_balances" => daily_balances.size,
        "categories" => data["categories"].size, "accounts" => data["accounts"].size }.merge(balance_summary)
    end

    def commit!
      result = %w[transactions balances accounts categories duplicates skipped changed_transactions already_imported skipped_duplicates
        asset_valuations existing_daily_balances_preserved existing_asset_valuations_preserved skipped_balances].index_with { 0 }
      @user.with_lock do
        @batch.with_lock do
          raise ArgumentError, "This batch was already imported" if @batch.imported_at
          # Refresh duplicate checks under the user's lock; another batch may have
          # been confirmed since the preview was displayed.
          refresh_preview
          raise ArgumentError, errors.first if errors.any?
          raise ArgumentError, "This workbook has no transactions or balances" if rows.empty? && daily_balances.empty?
          import_summary = summary
          resolved_accounts = import_accounts(result)
          categories = import_categories(result)
          import_transactions(resolved_accounts, categories, result)
          import_balances(resolved_accounts, result)
          import_asset_valuations(result)
          resolved_selections = data["accounts"].to_h do |source|
            [source["key"], resolved_accounts[source["key"]]&.id&.to_s || account_selection(source)]
          end
          @batch.update!(imported_at: Time.current, csv_text: "Imported (source file cleared)", settings: @batch.settings.merge(
            "accounts" => resolved_selections, "category_mapping" => @category_mapping,
            "result" => result, "summary" => import_summary, "warnings" => data["warnings"], "autocat_reference" => data["rules"],
            "changed_source_rows" => rows.select { |row| row[:conflict] }.map { |row| row[:data].slice("row", "name", "date").merge("reason" => row[:reason]) }))
        end
      end
      result
    end

    private

    def refresh_preview
      @currency = @batch.settings.fetch("currency", "USD")
      raise ArgumentError, "Invalid currency" unless CURRENCIES.include?(currency)
      @account_mapping = TillerAccountMapping.new(@batch, currency: currency)
      @sources = data.fetch("accounts").index_by { |source| source["key"] }
      @errors = data.fetch("errors").dup
      @sources.each_value { |source| @errors.concat(account_mapping.errors(source)) }
      balance_keys = daily_balances.map { |row| row["account_key"] }.to_set
      targets = data["accounts"].select { |source| balance_keys.include?(source["key"]) }.group_by { |source| account_selection(source) }
      targets.each do |target, sources|
        next if %w[new transactions_only].include?(target) || sources.one?
        @errors << "Choose a different destination for #{sources.map { |source| source['name'] }.join(', ')}. Two balance histories cannot share one destination."
      end
      build_rows
      build_balance_rows
    end

    def build_rows
      transactions = data.fetch("transactions")
      existing_records = @user.transactions.where(source: "import").where.not(source_transaction_id: nil).pluck(:source_transaction_id, :iso_currency_code).to_h
      existing_ids = existing_records.keys.to_set
      if transactions.any? { |row| existing_records.key?(row["source_transaction_id"]) && existing_records[row["source_transaction_id"]] != currency }
        @errors << "The workbook currency differs from previously imported transactions. Choose the original currency."
      end
      existing_tiller_ids = @user.transactions.where(source: "import").pluck(Arel.sql("raw_payload -> 'tiller' ->> 'Transaction ID'")).compact.to_set
      dates = transactions.map { |row| Date.iso8601(row["date"]) }
      possible = if dates.any?
        @user.transactions.roots.where(iso_currency_code: currency, date: (dates.min - 14)..(dates.max + 14))
          .pluck(:date, :amount, :name, :merchant_name, :source, :source_transaction_id, :account_id)
      else
        []
      end
      by_amount = possible.group_by { |row| row[1] }
      @rows = transactions.map do |row|
        date = Date.iso8601(row["date"])
        mapped_account = account_mapping.account(@sources.fetch(row["account_key"]))
        reason = nil
        by_amount.fetch(BigDecimal(row["amount"]), []).each do |entry|
          next if entry[5] == row["source_transaction_id"]
          # A mapped bank account, exact date and signed amount can identify a
          # possible duplicate even when a bank calls the purchase PAYMENT.
          if mapped_account && entry[4] == "plaid" && entry[6] == mapped_account.id && entry[0] == date
            reason = "Bank transaction has the same account, date and amount (#{entry[2]})."
            break
          end
          same_name = [entry[2], entry[3]].compact.any? { |name| normalize(name) == normalize(row["name"]) }
          if same_name && (entry[0] == date || (entry[4] == "plaid" && (entry[0] - date).abs <= 14))
            reason ||= "Existing transaction has the same amount and description (#{entry[0]})."
          end
        end
        changed_source_id = existing_tiller_ids.include?(row.dig("metadata", "Transaction ID")) && !existing_ids.include?(row["source_transaction_id"])
        reason ||= "Repeated source row in this workbook." if row["file_duplicate"]
        reason = "This Tiller ID already exists with a different date, amount or account. Existing transaction kept; source change skipped." if changed_source_id
        { data: row, existing: existing_ids.include?(row["source_transaction_id"]), duplicate: !changed_source_id && reason.present?, conflict: changed_source_id, reason: reason }
      end
    end

    def build_balance_rows
      snapshots = @user.balance_snapshots.pluck(:account_id, :as_of_date).to_set
      valuations = AssetValuation.where(manual_asset_id: manual_assets.map(&:id)).pluck(:manual_asset_id, :valued_on).to_set
      @balance_rows = daily_balances.map do |row|
        source = @sources.fetch(row["account_key"])
        date = Date.iso8601(row["date"])
        status = if (asset = account_mapping.asset(source))
          amount = BigDecimal(row["balance"])
          @errors << "#{source['name']} on #{date}: asset valuations require a nonnegative amount with at most two decimal places." if amount.negative? || amount.round(2) != amount
          valuations.include?([asset.id, date]) ? "existing_asset_valuations_preserved" : "new_asset_valuations"
        elsif account_selection(source) == "transactions_only"
          "skipped_balances"
        else
          account = account_mapping.account(source)
          snapshots.include?([account&.id, date]) ? "existing_daily_balances_preserved" : "new_balances"
        end
        { data: row, status: status }
      end
    end

    def normalize(name)
      name.to_s.downcase.squish
    end

    def source_key(source)
      "tiller:#{source['key']}"
    end

    def import_accounts(result)
      selected = data["accounts"].to_h do |source|
        selection = account_selection(source)
        account = case selection
        when "transactions_only" then nil
        when /\Aasset:\d+\z/ then nil
        when "new"
          result["accounts"] += 1
          @user.accounts.create!(import_source_key: source_key(source), name: source["name"], mask: source["mask"].to_s.last(4).presence,
            account_type: account_type(source), iso_currency_code: currency, net_worth_excluded: source["hidden"], import_metadata: source)
        else
          account = @user.accounts.find(selection)
          if account.import_source_key.blank? && !source["key"].start_with?("legacy:")
            account.update!(import_source_key: source_key(source), import_metadata: source)
          end
          account
        end
        [source["key"], account]
      end
      selected
    end

    def account_type(source)
      if source["class"] == "Liability"
        source["type"].to_s.upcase == "CREDIT" ? "credit" : "loan"
      elsif %w[INDIVIDUAL INVESTMENT BROKERAGE_CASH].include?(source["type"].to_s.upcase)
        "investment"
      elsif %w[CHECKING SAVINGS MONEY_MARKET DIGITAL_WALLET].include?(source["type"].to_s.upcase)
        "depository"
      else
        "other"
      end
    end

    def import_categories(result)
      # Use personal categories only; another user's/default category is never changed.
      @category_mapping = account_mapping.saved_categories.dup
      # Older receipts did not save category mappings. Recover only unambiguous
      # source choices that still have import provenance, including renamed categories.
      @user.transactions.where(source: "import", category_origin: "import").where.not(category_id: nil)
        .pluck(Arel.sql("raw_payload ->> 'import_category'"), :category_id).group_by(&:first).each do |name, entries|
          ids = entries.map(&:last).uniq
          @category_mapping[name] ||= ids.first.to_s if name.present? && ids.one?
        end
      needed = rows.select { |row| importable?(row) }.map { |row| row[:data]["category"] }.to_set
      first_import = !@user.import_batches.where.not(imported_at: nil).where("settings ->> 'format' = 'tiller'").exists?
      data["categories"].select { |source| first_import || needed.include?(source["name"]) }.to_h do |source|
        mapped = @user.categories.find_by(id: @category_mapping[source["name"]])
        next [source["name"], mapped] if mapped
        parent = if source["group"].present? && source["group"] != source["name"]
          category = @user.categories.find_or_initialize_by(name: source["group"], parent_id: nil)
          result["categories"] += 1 if category.new_record?
          category.save!
          category
        end
        category = @user.categories.find_or_initialize_by(name: source["name"], parent: parent)
        result["categories"] += 1 if category.new_record?
        category.save!
        @category_mapping[source["name"]] = category.id.to_s
        [source["name"], category]
      end
    end

    def importable?(row)
      !row[:existing] && !row[:conflict] && (!row[:duplicate] || @batch.settings["include_duplicates"] == "1")
    end

    def import_transactions(account_map, categories, result)
      now = Time.current
      records = rows.filter_map do |row|
        source = row[:data]
        unless importable?(row)
          result["skipped"] += 1
          result[row[:existing] ? "already_imported" : row[:conflict] ? "changed_transactions" : "skipped_duplicates"] += 1
          next
        end
        result["transactions"] += 1
        result["duplicates"] += 1 if row[:duplicate]
        category = categories[source["category"]]
        # Bulk insert preserves the source's categories and cash-flow choices;
        # running automatic rules here could change the imported ledger.
        { user_id: @user.id, account_id: account_map[source["account_key"]]&.id, source: "import",
          source_transaction_id: source["source_transaction_id"], date: Date.iso8601(source["date"]), name: source["name"], amount: BigDecimal(source["amount"]),
          source_account_name: source["source_account_name"], iso_currency_code: currency, category_id: category&.id,
          category_locked: true, category_origin: "import", category_reason: "Your Tiller category",
          original_description: source["original_description"], notes: source["notes"], tags: source["tags"].to_s,
          hidden: source["hidden"], transfer: source["transfer"], duplicate: row[:duplicate],
          classification_override: true, classification_origin: "import", classification_reason: "Your Tiller category type",
          raw_payload: { "import_category" => source["category"], "tiller" => source["metadata"], "import_duplicate_reason" => row[:reason] }, created_at: now, updated_at: now }
      end
      records.each_slice(500) { |slice| Transaction.insert_all!(slice) }
    end

    def import_balances(account_map, result)
      # Worth stores one observation per account/day. Select the final intraday
      # value, not a sum, and preserve existing bank observations on collisions.
      existing = @user.balance_snapshots.where(account_id: account_map.values.compact.map(&:id)).index_by { |snapshot| [snapshot.account_id, snapshot.as_of_date] }
      now = Time.current
      records = []
      daily_balances.each do |row|
        account = account_map[row["account_key"]]
        unless account
          result["skipped_balances"] += 1 unless account_mapping.asset(@sources.fetch(row["account_key"]))
          next
        end
        date = Date.iso8601(row["date"])
        snapshot = existing[[account.id, date]]
        if snapshot
          result["existing_daily_balances_preserved"] += 1
          next
        end
        records << { user_id: @user.id, account_id: account.id, as_of_date: date, current_balance: BigDecimal(row["balance"]),
          iso_currency_code: currency, import_metadata: row, created_at: now, updated_at: now }
      end
      records.each_slice(500) { |slice| BalanceSnapshot.insert_all!(slice) }
      result["balances"] = records.size
      changed_accounts = records.map { |record| record[:account_id] }.to_set
      account_map.values.compact.uniq.each do |account|
        next if account.plaid_item_id.present?
        next unless changed_accounts.include?(account.id)
        latest = account.balance_snapshots.order(as_of_date: :desc).first
        account.update!(current_balance: latest.current_balance, import_metadata: account.import_metadata.merge("as_of_date" => latest.as_of_date.iso8601)) if latest
      end
    end

    def import_asset_valuations(result)
      daily_balances.group_by { |row| account_mapping.asset(@sources.fetch(row["account_key"])) }.each do |asset, observations|
        next unless asset
        asset.with_lock do
          existing_dates = asset.asset_valuations.pluck(:valued_on).to_set
          observations.each do |row|
            date = Date.iso8601(row["date"])
            if existing_dates.include?(date)
              result["existing_asset_valuations_preserved"] += 1
              next
            end
            asset.asset_valuations.create!(valued_on: date, value: BigDecimal(row["balance"]))
            result["asset_valuations"] += 1
          end
          latest = asset.asset_valuations.order(valued_on: :desc).first
          asset.update!(value: latest.value, valued_on: latest.valued_on) if latest && latest.valued_on > asset.valued_on
        end
      end
    end
  end
end
