class ExpenseClassification
  LABELS = { "fixed" => "Fixed", "variable" => "Variable", "unclassified" => "Unclassified" }.freeze
  COLORS = { "fixed" => "#007b70", "variable" => "#c5842c", "unclassified" => "#87969c" }.freeze
  # These are editable defaults for shared categories, never guesses from a
  # recurring schedule, merchant, or a user's custom category name.
  FIXED_DEFAULTS = ["Rent", "Internet", "Mobile Phone"].freeze
  VARIABLE_DEFAULTS = ["Electricity", "Gas", "Water", "Food & Dining", "Shopping", "Gas & Fuel", "Parking", "Public Transportation", "Entertainment", "Travel"].freeze

  def initialize(user)
    @user = user
    @categories = Category.for_user(user).index_by(&:id)
    @overrides = user.category_expense_types.pluck(:category_id, :expense_type).to_h
    @category_types = {}
  end

  def for_transaction(transaction)
    transaction.expense_type.presence || transaction.parent&.expense_type.presence || for_category(transaction.category_id)
  end

  def for_category(category_id)
    @category_types[category_id] ||= begin
      chain = []
      category = @categories[category_id]
      while category && !chain.include?(category)
        chain << category
        category = @categories[category.parent_id]
      end
      override = chain.find { |entry| @overrides.key?(entry.id) }
      if override
        @overrides.fetch(override.id)
      else
        default = chain.filter_map { |entry| shared_default(entry) }.first
        default || "unclassified"
      end
    end
  end

  def filter(scope, type)
    scope = scope.where("transactions.amount > 0")
    ids = @categories.keys.select { |id| for_category(id) == type }
    ids << nil if type == "unclassified"
    explicit = scope.where(expense_type: type)
    inherited = scope.where(expense_type: nil, parent_id: @user.transactions.where(expense_type: type).select(:id))
    automatic = scope.where(expense_type: nil, category_id: ids)
    automatic = automatic.where(parent_id: nil).or(automatic.where(parent_id: @user.transactions.where(expense_type: nil).select(:id)))
    explicit.or(inherited).or(automatic)
  end

  private

  def shared_default(category)
    return unless category.system?
    return "fixed" if FIXED_DEFAULTS.include?(category.name)
    "variable" if VARIABLE_DEFAULTS.include?(category.name)
  end
end
