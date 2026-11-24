module Imports
  class TillerAccountMapping
    GENERIC_NAMES = ["checking", "savings", "credit card", "mortgage loan", "imported account"].freeze
    attr_reader :accounts, :assets, :saved_selections, :saved_categories

    def initialize(batch, currency:)
      @batch = batch
      @currency = currency
      @accounts = batch.user.accounts.includes(plaid_item: :institution).order(:name).to_a
      @assets = batch.user.manual_assets.order(:name).to_a
      @saved_selections = {}
      @saved_categories = {}
      batch.user.import_batches.where.not(imported_at: nil).where("settings ->> 'format' = 'tiller'").order(:imported_at, :id).pluck(:settings).each do |settings|
        saved_selections.merge!(settings.fetch("accounts", {}).reject { |_, value| value == "new" })
        # Also understands the mapping recorded by the first assisted import.
        settings.fetch("manual_asset_mapping", {}).each { |key, id| saved_selections[key] = "asset:#{id}" }
        saved_categories.merge!(settings.fetch("category_mapping", {}))
      end
    end

    def selection(source)
      requested = @batch.settings.fetch("accounts", {})[source["key"]].presence
      known = established(source)
      # Another import may have created this destination after the form loaded.
      return known if requested == "new" && known
      requested || known || saved_selection(source) || suggestion(source) ||
        (source["latest_at"] ? "new" : "transactions_only")
    end

    def established(source)
      account = accounts.find { |candidate| candidate.import_source_key == "tiller:#{source['key']}" }
      return account.id.to_s if account
      saved = saved_selection(source)
      saved if saved&.start_with?("asset:")
    end

    def explanation(source)
      return "Saved account choice" if established(source) || saved_selection(source)
      return if @batch.settings.fetch("accounts", {}).key?(source["key"])
      suggested = suggestion(source)
      return unless suggested
      return "Suggested: matching asset name" if suggested.start_with?("asset:")
      source["key"].start_with?("legacy:") ? "Suggested: matching account name" : "Suggested: matching bank and account number"
    end

    def account(source)
      value = selection(source)
      accounts.find { |candidate| candidate.id.to_s == value } if value.match?(/\A\d+\z/)
    end

    def asset(source)
      value = selection(source)
      assets.find { |candidate| "asset:#{candidate.id}" == value } if value.start_with?("asset:")
    end

    def errors(source)
      value = selection(source)
      if established(source) && value != established(source)
        return ["#{source['name']} was previously imported. Keep its existing account mapping."]
      end
      return [] if %w[new transactions_only].include?(value)
      target = account(source) || asset(source)
      return ["Choose an available account or asset for #{source['name']}."] unless target
      target_currency = target.is_a?(Account) ? target.iso_currency_code : target.currency
      return ["#{target.name} uses a different currency."] if target_currency != @currency
      if target.is_a?(ManualAsset)
        return ["#{source['name']} must be a visible Asset to import valuations into #{target.name}."] if source["class"] != "Asset" || source["hidden"]
      else
        if source["class"].present? && (%w[credit loan].include?(target.account_type) != (source["class"] == "Liability"))
          return ["#{target.name} has a different asset/liability classification. Choose an account with the same classification."]
        end
        if target.import_source_key.present? && target.import_source_key != "tiller:#{source['key']}" && !source["key"].start_with?("legacy:")
          return ["#{target.name} is already mapped to another Tiller account."]
        end
      end
      []
    end

    private

    def saved_selection(source)
      value = saved_selections[source["key"]]
      return value if value == "transactions_only"
      return value if accounts.any? { |account| account.id.to_s == value }
      return value if assets.any? { |asset| "asset:#{asset.id}" == value }
    end

    def suggestion(source)
      if source["key"].start_with?("manual:") && source["class"] == "Asset" && !source["hidden"]
        matches = assets.select { |asset| asset.currency == @currency && normalize(asset.name) == normalize(source["name"]) }
        return "asset:#{matches.first.id}" if matches.one?
      end
      eligible = accounts.select do |account|
        account.plaid_item_id.present? && account.iso_currency_code == @currency &&
          (source["class"].blank? || (%w[credit loan].include?(account.account_type) == (source["class"] == "Liability"))) &&
          (source["key"].start_with?("legacy:") || account.import_source_key.blank? || account.import_source_key == "tiller:#{source['key']}")
      end
      matches = if source["key"].start_with?("legacy:")
        return if GENERIC_NAMES.include?(normalize(source["name"]))
        eligible.select { |account| [account.name, account.official_name].compact.any? { |name| normalize(name) == normalize(source["name"]) } }
      else
        mask = source["mask"].to_s[/\d{4}\z/]
        return unless mask && source["institution"].present?
        eligible.select { |account| account.mask == mask && normalize(account.plaid_item.institution.name) == normalize(source["institution"]) }
      end
      matches.first.id.to_s if matches.one?
    end

    def normalize(value)
      value.to_s.downcase.squish
    end
  end
end
