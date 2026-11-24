class TransactionSearch
  FILTER_KEYS = %w[q account_id source_account_name category_id from to currency source flow min_amount max_amount tag flag reportable expense_type sort direction per_page].freeze
  SORTS = { "date" => "transactions.date", "name" => "transactions.name", "amount" => "transactions.amount" }.freeze
  CURRENCIES = %w[USD CAD EUR GBP].freeze
  attr_reader :errors, :sort, :direction

  def initialize(user:, params:)
    @user = user
    @params = params
    @errors = []
    @sort = SORTS.key?(params[:sort]) ? params[:sort] : "date"
    @direction = %w[asc desc].include?(params[:direction]) ? params[:direction] : "desc"
  end

  def call
    scope = @user.transactions.tracked.where(is_split: false)
    if @params[:q].present?
      pattern = "%#{Transaction.sanitize_sql_like(@params[:q].to_s.strip)}%"
      scope = scope.left_joins(:account, :category).where(
        "transactions.name ILIKE :term OR transactions.merchant_name ILIKE :term OR transactions.original_description ILIKE :term OR transactions.notes ILIKE :term OR transactions.tags ILIKE :term OR transactions.source_account_name ILIKE :term OR accounts.name ILIKE :term OR categories.name ILIKE :term", term: pattern
      )
    end
    if @params[:account_id].present?
      account = @user.accounts.tracked.find_by(id: @params[:account_id])
      errors << "Choose one of your linked accounts." unless account
      scope = scope.where(account_id: account&.id)
    end
    scope = scope.where(source_account_name: @params[:source_account_name]) if @params[:source_account_name].present?
    if @params[:category_id].present?
      if @params[:category_id] == "uncategorized"
        scope = scope.where(category_id: nil)
      else
        category = Category.for_user(@user).find_by(id: @params[:category_id])
        errors << "Choose an available category." unless category
        scope = scope.where(category_id: category&.subtree_ids || [])
      end
    end
    from = parse_date(:from)
    to = parse_date(:to)
    errors << "The end date must be on or after the start date." if from && to && from > to
    scope = scope.where(date: from..) if from
    scope = scope.where(date: ..to) if to
    if @params[:currency].present?
      errors << "Choose a supported currency." unless CURRENCIES.include?(@params[:currency])
      scope = scope.where(iso_currency_code: @params[:currency])
    end
    if @params[:source].present?
      errors << "Choose a valid transaction source." unless Transaction.sources.key?(@params[:source])
      scope = scope.where(source: @params[:source])
    end
    if @params[:tag].present?
      scope = scope.where("EXISTS (SELECT 1 FROM unnest(string_to_array(transactions.tags, ',')) AS tag_value WHERE lower(btrim(tag_value)) = ?)", @params[:tag].strip.downcase)
    end
    scope = scope.where("transactions.amount > 0") if @params[:flow] == "outflow"
    scope = scope.where("transactions.amount < 0") if @params[:flow] == "inflow"
    minimum = parse_amount(:min_amount)
    maximum = parse_amount(:max_amount)
    errors << "Maximum amount must be at least the minimum amount." if minimum && maximum && minimum > maximum
    scope = scope.where("ABS(transactions.amount) >= ?", minimum) if minimum
    scope = scope.where("ABS(transactions.amount) <= ?", maximum) if maximum
    scope = scope.where.not(category_suggestion_reason: nil) if @params[:flag] == "category_review"
    scope = scope.where.not(suggested_classification: nil) if @params[:flag] == "suggested"
    if %w[hidden duplicate transfer card_payment split_needs_review pending].include?(@params[:flag])
      flag = @params[:flag]
      scope = scope.where(flag => true).or(scope.where(parent_id: @user.transactions.where(flag => true).select(:id)))
    end
    scope = scope.reportable if @params[:reportable] == "1"
    if @params[:expense_type].present?
      if ExpenseClassification::LABELS.key?(@params[:expense_type])
        scope = ExpenseClassification.new(@user).filter(scope, @params[:expense_type])
      else
        errors << "Choose Fixed, Variable, or Unclassified expenses."
      end
    end
    errors.empty? ? scope : scope.none
  end

  def ordered(scope)
    scope.reorder(Arel.sql("#{SORTS.fetch(sort)} #{direction.upcase}, transactions.id #{direction.upcase}"))
  end

  private

  def parse_date(key)
    Date.iso8601(@params[key]) if @params[key].present?
  rescue Date::Error, TypeError
    errors << "#{key.to_s.humanize} must be a valid date (YYYY-MM-DD)."
    nil
  end

  def parse_amount(key)
    return if @params[key].blank?
    amount = BigDecimal(@params[key].to_s)
    raise ArgumentError unless amount.finite? && amount >= 0
    amount
  rescue ArgumentError
    errors << "#{key.to_s.humanize} must be a nonnegative number."
    nil
  end
end
