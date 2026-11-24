class DuplicateTransactionReview
  POSTING_WINDOW_DAYS = 14

  def initialize(user)
    @user = user
  end

  def groups
    candidates = @user.transactions.tracked.roots.where(duplicate: false, pending: false, transfer: false, card_payment: false)
    shared_keys = candidates.group(:amount, :iso_currency_code).having("COUNT(*) > 1")
    candidates.where("(transactions.amount, COALESCE(transactions.iso_currency_code, '')) IN (?)",
      shared_keys.reselect(:amount, Arel.sql("COALESCE(iso_currency_code, '')")))
      .includes(:account).order(date: :desc, id: :asc)
      .group_by { |entry| [entry.amount, entry.iso_currency_code, normalized_name(entry)] }
      .values.flat_map { |entries| matching_groups(entries) }
  end

  private

  def matching_groups(entries)
    by_date = entries.group_by(&:date)
    exact = by_date.values.select { |same_day| same_day.size > 1 }
    nearby = entries.select(&:source_plaid?).flat_map do |bank_entry|
      (1..POSTING_WINDOW_DAYS).flat_map do |days|
        [bank_entry.date - days, bank_entry.date + days].flat_map do |date|
          by_date.fetch(date, []).select(&:source_import?).map { |import_entry| [bank_entry, import_entry] }
        end
      end
    end
    exact + nearby
  end

  def normalized_name(entry)
    (entry.merchant_name.presence || entry.name).downcase.squish
  end
end
