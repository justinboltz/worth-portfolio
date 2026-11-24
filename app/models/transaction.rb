class Transaction < ApplicationRecord
  belongs_to :user
  belongs_to :account, optional: true
  belongs_to :plaid_item, optional: true
  belongs_to :category, optional: true
  belongs_to :suggested_category, class_name: "Category", optional: true

  def merchant_key
    direction = amount.to_d.negative? ? "inflow" : "outflow"
    identity = if merchant_entity_id.present?
      "entity:#{merchant_entity_id}"
    elsif merchant_name.present?
      "merchant:#{merchant_name.downcase.strip.gsub(/\s+/, ' ')}"
    else
      text = name.to_s.downcase.strip.gsub(/\s+/, ' ')
      return if text.length < 4 || text.match?(/\A(?:purchase|debit card purchase|card purchase|payment|online payment|deposit|withdrawal|transfer|transaction|unknown|check|pos)\z/)
      "description:#{text}"
    end
    "#{direction}:#{identity}"
  end
  belongs_to :matched_transaction, class_name: "Transaction", optional: true
  attr_writer :classification_choice
  belongs_to :parent, class_name: "Transaction", optional: true
  has_many :splits, class_name: "Transaction", foreign_key: :parent_id, dependent: :destroy
  enum :source, { plaid: "plaid", import: "import", manual: "manual" }, prefix: true
  scope :tracked, -> { where(account_id: nil).or(where(account_id: Account.tracked.select(:id))) }
  scope :visible_in_reports, -> { tracked.where(hidden: false, duplicate: false, transfer: false, card_payment: false, pending: false, split_needs_review: false) }
  scope :reportable, -> { visible_in_reports.where(is_split: false).where(parent_id: nil).or(visible_in_reports.where(is_split: false, parent_id: Transaction.visible_in_reports.select(:id))) }
  scope :roots, -> { where(parent_id: nil) }
  validates :amount, numericality: true
  validates :expense_type, inclusion: { in: ExpenseClassification::LABELS.keys }, allow_nil: true
  before_validation { self.expense_type = nil if expense_type.blank? }
  validates :date, :name, :source, presence: true
  validate :owned_associations
  before_validation :apply_classification_choice
  before_validation :apply_rules, on: :create
  before_validation :normalize_tags

  def classification_choice
    @classification_choice || (classification_override? ? (card_payment? ? "card_payment" : transfer? ? "transfer" : "regular") : "automatic")
  end

  def apply_classification_choice
    return unless @classification_choice
    unless %w[automatic regular transfer card_payment].include?(@classification_choice)
      errors.add(:classification_choice, "is invalid")
      return
    end
    self.classification_override = @classification_choice != "automatic"
    self.classification_origin = classification_override? ? "manual" : nil
    self.classification_reason = classification_override? ? "Your manual cash-flow classification" : nil
    self.transfer = @classification_choice == "transfer"
    self.card_payment = @classification_choice == "card_payment"
    self.matched_transaction_id = nil
    self.suggested_classification = nil
    self.suggestion_reason = nil
  end

  def account_label
    source_account_name.presence || account&.name || "Manual / cash"
  end

  def excluded?
    hidden? || duplicate? || transfer? || card_payment? || pending? || split_needs_review?
  end

  def apply_rules
    return unless user && parent_id.nil?
    user.transaction_rules.order(:id).each { |rule| rule.apply_to(self) }
  end

  def replace_splits!(rows)
    raise ArgumentError, "A split cannot be split again" if parent_id?
    rows = rows.reject { |row| row[:name].blank? && row[:amount].blank? }
    raise ArgumentError, "Enter at least two split rows" if rows.size < 2
    values = rows.map { |row| BigDecimal(row.fetch(:amount).to_s) }
    raise ArgumentError, "Splits must add up to the original amount" unless values.sum == amount
    transaction do
      splits.destroy_all
      rows.each_with_index do |row, i|
        category = row[:category_id].present? ? Category.for_user(user).find(row[:category_id]) : nil
        splits.create!(user: user, account: account, plaid_item: plaid_item, source: source,
          source_account_name: source_account_name, date: date, amount: values[i], name: row[:name].presence || name,
          category: category, category_locked: true, category_origin: "split", category_reason: "Your split category", iso_currency_code: iso_currency_code, tags: tags)
      end
      update!(is_split: true, split_needs_review: false)
    end
  end

  private
  def normalize_tags
    self.tags = tags.to_s.split(",").map(&:strip).reject(&:blank?).uniq.join(", ")
  end

  def owned_associations
    [account, plaid_item, parent].compact.each { |record| errors.add(:base, "Invalid ownership") if record.user_id != user_id }
    errors.add(:category, "is unavailable") if category && !(category.system? || category.user_id == user_id)
  end
end
