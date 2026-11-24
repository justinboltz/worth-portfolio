# Uses cached data only. Automated flags are replaceable; manual/rule overrides are durable.
class CashFlowClassifier
  TRUSTED_CONFIDENCE = %w[HIGH VERY_HIGH].freeze
  TRANSFER_CODES = %w[TRANSFER_IN_ACCOUNT_TRANSFER TRANSFER_OUT_ACCOUNT_TRANSFER].freeze
  CARD_CODES = %w[LOAN_PAYMENTS_CREDIT_CARD_PAYMENT].freeze
  CARD_DESCRIPTION = /\b(?:credit\s*card\s+(?:payment|pmt)|(?:cardmember|card\s+services)\s+(?:payment|pmt))\b/i
  CARD_ACCOUNT_PAYMENT = /\b(?:automatic|autopay|online|mobile|electronic)\s+(?:payment|pmt)\b|\bpayment\s+(?:received|thank\s*you)\b/i
  TRANSFER_DESCRIPTION = /\b(?:transfer|xfer|xfr|vault)\b/i
  Result = Struct.new(:automatic_transfers, :automatic_card_payments, :suggestions, keyword_init: true)

  def self.call(user:)
    new(user).call
  end

  def initialize(user)
    @user = user
  end

  def call
    @user.with_lock do
      @accounts = @user.accounts.to_a
      @rows = @user.transactions.roots.includes(:account, :category).order(:id).to_a
      @signals = @rows.to_h { |row| [row.id, signal(row)] }
      @by_amount = @rows.select { |row| matchable?(row) }.group_by { |row| [row.iso_currency_code, row.amount] }
      @pairs = find_pairs
      @rows.each { |row| classify(row) }
      Result.new(
        automatic_transfers: @rows.count { |row| row.classification_origin == "automatic" && row.transfer? },
        automatic_card_payments: @rows.count { |row| row.classification_origin == "automatic" && row.card_payment? },
        suggestions: @rows.count { |row| row.suggested_classification.present? }
      )
    end
  end

  private

  def signal(row)
    if row.classification_override? && (row.transfer? || row.card_payment?)
      return { kind: row.card_payment? ? "card_payment" : "transfer", trusted: true, reason: "Your confirmed classification" }
    end
    pfc = row.raw_payload.to_h.fetch("personal_finance_category", {}) || {}
    code = pfc["detailed"]
    confidence = pfc["confidence_level"]
    if CARD_CODES.include?(code)
      return { kind: "card_payment", trusted: TRUSTED_CONFIDENCE.include?(confidence), reason: "Bank card-payment category (#{confidence.presence || 'unknown confidence'})" }
    elsif TRANSFER_CODES.include?(code)
      return { kind: "transfer", trusted: TRUSTED_CONFIDENCE.include?(confidence), reason: "Bank account-transfer category (#{confidence.presence || 'unknown confidence'})" }
    end
    # Imported categories reflect the source user's categorization, not an inferred bank transfer.
    category = row.raw_payload.to_h["import_category"].presence || row.category&.display_name
    leaf = category.to_s.split(/\s*>\s*|\s*:\s*/).last.to_s.downcase
    return { kind: "card_payment", trusted: true, reason: "Explicit credit-card payment category" } if ["credit card payment", "credit card payments"].include?(leaf)
    return { kind: "transfer", trusted: true, reason: "Explicit transfer category" } if %w[transfer transfers].include?(leaf)
    text = description(row)
    return nil if text.match?(/\b(?:fees?|interest|refund|reversal|cash advance|insurance|protection)\b/i)
    if text.match?(CARD_DESCRIPTION) || (row.account&.account_type == "credit" && row.amount.negative? && text.match?(CARD_ACCOUNT_PAYMENT))
      return { kind: "card_payment", trusted: true, reason: "Explicit card-payment description#{' on a credit account' if row.account&.account_type == 'credit'}" }
    end
    return { kind: "transfer", trusted: false, reason: "Transfer-like description; needs a matching owned account" } if text.match?(TRANSFER_DESCRIPTION)
    nil
  end

  def description(row)
    [row.name, row.original_description].compact.join(" ")
  end

  def matchable?(row)
    !row.pending? && !row.hidden? && !row.duplicate? && !row.amount.zero? && row.iso_currency_code.present? && account_key(row).present? && row.account&.account_type != "loan" && !definite_non_transfer?(row)
  end

  def definite_non_transfer?(row)
    pfc = row.raw_payload.to_h.fetch("personal_finance_category", {}) || {}
    TRUSTED_CONFIDENCE.include?(pfc["confidence_level"]) && pfc["detailed"].present? &&
      !(TRANSFER_CODES + CARD_CODES).include?(pfc["detailed"]) && !@signals[row.id]&.fetch(:trusted)
  end

  def account_key(row)
    return "linked:#{row.account_id}" if row.account_id
    return unless row.source_account_name.present?
    name = row.source_account_name.downcase.strip
    accounts = @accounts.select { |account| account.name.downcase.strip == name }
    accounts.one? ? "linked:#{accounts.first.id}" : "source:#{name}"
  end

  def opposite_candidates(row)
    (@by_amount[[row.iso_currency_code, -row.amount]] || []).select do |other|
      account_key(row) != account_key(other) && (row.date - other.date).abs <= 3 &&
        !(other.classification_override? && !other.transfer? && !other.card_payment?) &&
        !(row.classification_override? && !row.transfer? && !row.card_payment?)
    end
  end

  def references_account?(row, other)
    text = description(row).downcase
    label = (other.source_account_name.presence || other.account&.name).to_s.downcase.strip
    # Generic account names are not evidence of a specific destination.
    meaningful = label.gsub(/\b(?:account|checking|savings|credit|card|joint|bank)\b/, "").strip
    label_match = meaningful.length >= 3 && text.match?(/(?<![a-z0-9])#{Regexp.escape(label)}(?![a-z0-9])/)
    mask = other.account&.mask
    label_match || (mask.present? && mask.length >= 4 && text.match?(/(?<!\d)#{Regexp.escape(mask)}(?!\d)/))
  end

  def pair_evidence?(row, other)
    a, b = @signals[row.id], @signals[other.id]
    # Equal amounts alone never hide unrelated purchases, refunds, salary or P2P payments.
    return false unless a || b
    return true if references_account?(row, other) || references_account?(other, row)
    a && b && (a[:kind] == b[:kind] || a[:kind] == "card_payment" || b[:kind] == "card_payment")
  end

  def pair_rank(row, other)
    outgoing, incoming = row.amount.positive? ? [row, other] : [other, row]
    # A named destination distinguishes multiple same-sized vault transfers from one checking account.
    named = (references_account?(outgoing, incoming) ? 2 : 0) + (references_account?(incoming, outgoing) ? 1 : 0)
    [named, -(row.date - other.date).abs]
  end

  def find_pairs
    choices = {}
    @rows.select { |row| matchable?(row) }.each do |row|
      candidates = opposite_candidates(row).select { |other| pair_evidence?(row, other) }
      if candidates.any?
        ranks = candidates.to_h { |other| [other.id, pair_rank(row, other)] }
        best = ranks.values.max
        candidates = candidates.select { |other| ranks[other.id] == best }
      end
      choices[row.id] = candidates.first if candidates.one?
    end
    choices.select { |id, other| choices[other.id]&.id == id }
  end

  def classify(row)
    return if row.classification_override?
    # Preserve any existing flag set by a caller that predates classification provenance.
    return if row.classification_origin != "automatic" && (row.transfer? || row.card_payment?)
    evidence = @signals[row.id]
    match = @pairs[row.id]
    kind, reason = nil
    if match
      kind = [evidence, @signals[match.id]].compact.any? { |s| s[:kind] == "card_payment" } ? "card_payment" : "transfer"
      kind = "card_payment" if [row.account&.account_type, match.account&.account_type].include?("credit")
      reason = "Opposite amounts in different owned accounts within 3 days, corroborated by transfer/payment details"
    elsif evidence&.fetch(:trusted)
      kind, reason = evidence.values_at(:kind, :reason)
    end
    attrs = { transfer: kind == "transfer", card_payment: kind == "card_payment", classification_origin: kind ? "automatic" : nil,
      classification_reason: reason, matched_transaction_id: match&.id,
      suggested_classification: kind ? nil : evidence&.fetch(:kind), suggestion_reason: kind ? nil : evidence&.fetch(:reason) }
    row.assign_attributes(attrs)
    row.update_columns(attrs.merge(updated_at: Time.current)) if row.changed?
  end
end
