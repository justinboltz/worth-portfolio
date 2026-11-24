# Deterministic, local categorization. It never calls a model or provider API.
class AutoCategorizer
  TRUSTED_CONFIDENCE = %w[HIGH VERY_HIGH].freeze
  PRIMARY_PATHS = {
    "INCOME" => ["Income"], "FOOD_AND_DRINK" => ["Food & Dining"], "GENERAL_MERCHANDISE" => ["Shopping"],
    "TRANSPORTATION" => ["Auto & Transport"], "RENT_AND_UTILITIES" => ["Bills & Utilities"],
    "ENTERTAINMENT" => ["Entertainment"], "MEDICAL" => ["Health & Fitness"], "PERSONAL_CARE" => ["Health & Fitness"],
    "TRAVEL" => ["Travel"], "BANK_FEES" => ["Fees & Charges"], "HOME_IMPROVEMENT" => ["Home"],
    "GENERAL_SERVICES" => ["Services"], "LOAN_PAYMENTS" => ["Bills & Utilities"]
  }.freeze
  DETAIL_PATHS = {
    "INCOME_SALARY" => ["Income", "Paycheck"], "INCOME_INTEREST_EARNED" => ["Income", "Interest Income"],
    "INCOME_CONTRACTOR" => ["Income", "Other Income"], "INCOME_DIVIDENDS" => ["Income", "Other Income"],
    "INCOME_RETIREMENT_PENSION" => ["Income", "Other Income"], "INCOME_UNEMPLOYMENT" => ["Income", "Other Income"],
    "FOOD_AND_DRINK_GROCERIES" => ["Food & Dining", "Groceries"], "FOOD_AND_DRINK_COFFEE" => ["Food & Dining", "Coffee Shops"],
    "FOOD_AND_DRINK_FAST_FOOD" => ["Food & Dining", "Restaurants"], "FOOD_AND_DRINK_RESTAURANT" => ["Food & Dining", "Restaurants"],
    "FOOD_AND_DRINK_RESTAURANTS" => ["Food & Dining", "Restaurants"],
    "GENERAL_MERCHANDISE_CLOTHING_AND_ACCESSORIES" => ["Shopping", "Clothing"],
    "GENERAL_MERCHANDISE_ELECTRONICS" => ["Shopping", "Electronics & Software"],
    "GENERAL_MERCHANDISE_HOME_GOODS" => ["Shopping", "Home Goods"],
    "GENERAL_MERCHANDISE_GIFTS_AND_NOVELTIES" => ["Gifts & Donations"],
    "HOME_IMPROVEMENT_FURNITURE" => ["Shopping", "Home Goods"],
    "TRANSPORTATION_GAS" => ["Auto & Transport", "Gas & Fuel"], "TRANSPORTATION_PARKING" => ["Auto & Transport", "Parking"],
    "TRANSPORTATION_PUBLIC_TRANSIT" => ["Auto & Transport", "Public Transportation"],
    "RENT_AND_UTILITIES_ELECTRICITY" => ["Bills & Utilities", "Electricity"],
    "RENT_AND_UTILITIES_GAS" => ["Bills & Utilities", "Gas"], "RENT_AND_UTILITIES_RENT" => ["Bills & Utilities", "Rent"],
    "RENT_AND_UTILITIES_INTERNET_AND_CABLE" => ["Bills & Utilities", "Internet"],
    "RENT_AND_UTILITIES_TELEPHONE" => ["Bills & Utilities", "Mobile Phone"], "RENT_AND_UTILITIES_WATER" => ["Bills & Utilities", "Water"],
    "LOAN_PAYMENTS_MORTGAGE_PAYMENT" => ["Bills & Utilities", "Mortgage"],
    "GENERAL_SERVICES_INSURANCE" => ["Bills & Utilities", "Insurance"],
    "GENERAL_SERVICES_POSTAGE_AND_SHIPPING" => ["Shopping"],
    "GENERAL_SERVICES_AUTOMOTIVE" => ["Auto & Transport"],
    "ENTERTAINMENT_TV_AND_MOVIES" => ["Entertainment"], "ENTERTAINMENT_VIDEO_GAMES" => ["Entertainment"],
    "GOVERNMENT_AND_NON_PROFIT_DONATIONS" => ["Gifts & Donations"],
    "GOVERNMENT_AND_NON_PROFIT_TAX_PAYMENT" => ["Taxes"]
  }.freeze
  Result = Struct.new(:categorized, :suggestions, :uncategorized, keyword_init: true)
  def self.call(user:)
    new(user).call
  end
  def initialize(user)
    @user = user
  end
  def call
    @user.with_lock do
      @categories = Category.for_user(@user).includes(:parent).to_a
      @by_path = @categories.group_by { |c| c.display_name.downcase }
      @rules = @user.transaction_rules.where.not(category_id: nil).includes(:category).order(:id).to_a
      @rows = @user.transactions.roots.includes(:category).order(:id).to_a
      @history = @rows.select { |t| !t.excluded? && !t.is_split? && t.category_locked? && t.category_origin == "manual" && t.category_id && t.merchant_key.present? }.group_by(&:merchant_key)
      eligible = @rows.reject { |t| t.excluded? || t.is_split? }
      eligible.each { |row| categorize(row) }
      Result.new(categorized: eligible.count { |t| t.category_id.present? }, suggestions: eligible.count { |t| t.category_suggestion_reason.present? }, uncategorized: eligible.count { |t| t.category_id.nil? })
    end
  end
  private
  def categorize(row)
    return if row.category_locked? || (row.category_id.present? && row.category_origin.blank?)
    category, origin, reason = nil
    rule = @rules.reverse.find { |r| r.matches?(row) && available?(r.category_id) && (r.merchant_key.present? || (r.effective_from || r.created_at) <= row.created_at) }
    if rule
      category, origin, reason = rule.category, "rule", rule.explanation
    else
      known = (row.merchant_key.present? ? @history.fetch(row.merchant_key, []) : []).reject { |t| t.id == row.id }
      if known.size >= 2 && known.map(&:category_id).uniq.one?
        category = @categories.find { |c| c.id == known.first.category_id }
        origin, reason = "merchant_history", "Your consistent category on #{known.size} previous transactions from this merchant" if category
      end
    end
    suggestion, suggestion_reason = nil
    unless category
      bank = row.raw_payload.to_h.fetch("personal_finance_category", {}) || {}
      code, confidence = bank.values_at("detailed", "confidence_level")
      mapped = category_for(code, bank["primary"])
      if mapped && TRUSTED_CONFIDENCE.include?(confidence)
        category, origin, reason = mapped, "provider", "Bank category: #{mapped.display_name} (#{confidence.downcase.tr('_', ' ')} confidence)"
      elsif mapped
        suggestion = mapped
        suggestion_reason = "Bank suggests #{mapped.display_name}; #{confidence.presence&.downcase&.tr('_', ' ') || 'unknown'} confidence needs review"
      elsif code.present? && !code.start_with?("TRANSFER_", "LOAN_DISBURSEMENTS_") && code != "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"
        suggestion_reason = "No matching existing category for #{code.downcase.tr('_', ' ')}; choose a category or add a rule"
      end
    end
    attrs = { category_id: category&.id, category_origin: origin, category_reason: reason,
      category_locked: origin == "rule", suggested_category_id: suggestion&.id, category_suggestion_reason: suggestion_reason }
    row.assign_attributes(attrs)
    row.update_columns(attrs.merge(updated_at: Time.current)) if row.changed?
  end
  def category_for(code, primary)
    return unless code.present?
    return if code.start_with?("TRANSFER_", "LOAN_DISBURSEMENTS_") || code == "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"
    path = DETAIL_PATHS[code]
    primary ||= PRIMARY_PATHS.keys.sort_by { |key| -key.length }.find { |key| code.start_with?("#{key}_") }
    candidates = [path, path&.size == 2 ? [path.first] : nil, PRIMARY_PATHS[primary]].compact.uniq
    candidates.each do |parts|
      matches = @by_path.fetch(parts.join(" > ").downcase, [])
      personal = matches.select { |c| c.user_id == @user.id }
      return personal.first if personal.one?
      return matches.first if personal.empty? && matches.one?
    end
    nil
  end
  def available?(id)
    @categories.any? { |c| c.id == id }
  end
end
