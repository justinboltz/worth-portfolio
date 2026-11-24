class TransactionRule < ApplicationRecord
  belongs_to :user
  belongs_to :category, optional: true
  belongs_to :account, optional: true
  DESCRIPTION_OPERATORS = { "contains" => "Contains", "equals" => "Equals", "starts_with" => "Starts with", "ends_with" => "Ends with" }.freeze
  validates :description_operator, inclusion: { in: DESCRIPTION_OPERATORS.keys }
  before_validation do
    self.match_text = match_text.to_s.strip.presence
    self.source_account_name = source_account_name.to_s.strip.presence
    self.effective_from ||= Time.current
  end
  validate do
    errors.add(:base, "Add a description or account condition") if match_text.blank? && merchant_key.blank? && account_id.blank? && source_account_name.blank?
    errors.add(:account, "is unavailable") if account_id.present? && (account.nil? || account.user_id != user_id)
    errors.add(:base, "Choose a linked account or an imported source account name, not both") if account_id.present? && source_account_name.present?
  end
  validates :kind, inclusion: { in: %w[regular transfer card_payment hidden] }
  validate do
    errors.add(:category, "is unavailable") if category && !(category.system? || category.user_id == user_id)
  end
  validates :merchant_key, uniqueness: { scope: :user_id }, allow_nil: true
  def matches?(transaction)
    return false if transaction.user_id != user_id
    conditions = []
    if merchant_key.present?
      conditions << (transaction.merchant_key == merchant_key)
    elsif match_text.present?
      description = transaction.name.to_s.downcase
      text = match_text.downcase
      conditions << case description_operator
      when "contains" then description.include?(text)
      when "equals" then description == text
      when "starts_with" then description.start_with?(text)
      when "ends_with" then description.end_with?(text)
      else false
      end
    end
    conditions << (transaction.account_id == account_id) if account_id.present?
    conditions << (transaction.source_account_name.to_s.strip.casecmp?(source_account_name)) if source_account_name.present?
    conditions.any? && conditions.all?
  end

  def explanation
    return "Your saved merchant preference" if merchant_key.present?
    return "Your description rule" unless account_id.present? || source_account_name.present?
    match_text.present? ? "Your account and description rule" : "Your account rule"
  end

  def apply_to(transaction)
    return unless matches?(transaction)
    if category && !(transaction.category_locked? && %w[manual import existing split].include?(transaction.category_origin))
      transaction.category = category
      transaction.category_origin = "rule"
      transaction.category_locked = true
      transaction.category_reason = explanation
      transaction.suggested_category_id = nil
      transaction.category_suggestion_reason = nil
    end
    transaction.tags = [transaction.tags, tags].reject(&:blank?).join(", ")
    if %w[transfer card_payment].include?(kind)
      return if transaction.classification_origin == "manual"
      transaction.classification_override = true
      transaction.classification_origin = "rule"
      transaction.classification_reason = explanation
      transaction.matched_transaction_id = nil
      transaction.suggested_classification = nil
      transaction.suggestion_reason = nil
    end
    transaction.transfer = true if kind == "transfer"
    transaction.card_payment = true if kind == "card_payment"
    transaction.hidden = true if kind == "hidden"
  end
end
