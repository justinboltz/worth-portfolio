require "digest"

class RecurringDetector
  Suggestion = Data.define(:key, :transaction, :frequency, :history, :minimum, :maximum)

  def self.key(transaction)
    return if transaction.merchant_key.blank?
    Digest::SHA256.hexdigest([transaction.merchant_key, transaction.iso_currency_code, transaction.account_id, transaction.account_id ? nil : transaction.source_account_name.presence].to_json)
  end

  def initialize(user, today: Date.current)
    @user, @today = user, today
  end

  def suggestions
    excluded = @user.recurring_items.where.not(detection_key: nil).pluck(:detection_key) + @user.recurring_dismissals.pluck(:detection_key)
    histories.filter_map do |key, history|
      next if key.nil? || excluded.include?(key)
      recent = history.last(6)
      next if recent.size < 3 || recent.map(&:date).uniq.size != recent.size
      frequency = detect_frequency(recent.map(&:date))
      next unless frequency
      latest = recent.last
      freshness = { "weekly" => 14, "biweekly" => 28, "monthly" => 45, "quarterly" => 110, "yearly" => 390 }.fetch(frequency)
      next if latest.date < @today - freshness
      amounts = recent.map { |row| row.amount.abs }
      median = amounts.sort[amounts.size / 2]
      next if amounts.any? { |amount| (amount - median).abs > median * 0.35 }
      Suggestion.new(key: key, transaction: latest, frequency: frequency, history: recent.reverse, minimum: amounts.min, maximum: amounts.max)
    end.sort_by { |suggestion| [-suggestion.transaction.date.jd, suggestion.transaction.name] }
  end

  def history_for(key)
    key ? histories.fetch(key, []).last(6).reverse : []
  end

  private

  def histories
    @histories ||= @user.transactions.roots.visible_in_reports.where(date: (@today - 3.years)..@today, iso_currency_code: TransactionSearch::CURRENCIES).where.not(amount: 0).includes(:account).order(:date, :id).group_by { |row| self.class.key(row) }
  end

  def detect_frequency(dates)
    RecurringItem::MONTHS.each do |frequency, months|
      return frequency if dates.each_cons(2).all? { |left, right| ((right.year * 12 + right.month) - (left.year * 12 + left.month)) == months && (right - left.advance(months: months)).abs <= 4 }
    end
    RecurringItem::DAYS.each do |frequency, days|
      tolerance = frequency == "weekly" ? 1 : 2
      return frequency if dates.each_cons(2).all? { |left, right| ((right - left) - days).abs <= tolerance }
    end
    nil
  end
end
