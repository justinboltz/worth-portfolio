class RecurringItem < ApplicationRecord
  FREQUENCIES = { "weekly" => "Weekly", "biweekly" => "Every two weeks", "monthly" => "Monthly", "quarterly" => "Every three months", "yearly" => "Yearly" }.freeze
  MONTHS = { "monthly" => 1, "quarterly" => 3, "yearly" => 12 }.freeze
  DAYS = { "weekly" => 7, "biweekly" => 14 }.freeze

  belongs_to :user
  belongs_to :account, optional: true
  scope :active, -> { where(status: "active") }
  before_validation { self.next_on = next_on.end_of_month if next_on && month_end? && MONTHS.key?(frequency) }
  validates :name, presence: true, length: { maximum: 120 }
  validates :amount, numericality: { greater_than: 0, less_than: 10_000_000_000 }
  validates :currency, inclusion: { in: TransactionSearch::CURRENCIES }
  validates :direction, inclusion: { in: %w[expense income] }
  validates :frequency, inclusion: { in: FREQUENCIES.keys }
  validates :status, inclusion: { in: %w[active paused] }
  validates :next_on, presence: true
  validate do
    errors.add(:base, "This recurring pattern is already tracked") if detection_key.present? && self.class.where(user_id: user_id, detection_key: detection_key).where.not(id: id).exists?
    errors.add(:account, "is unavailable") if account_id.present? && (!account || account.user_id != user_id)
    errors.add(:next_on, "must be between 1900 and twenty years from now") if next_on && !(Date.new(1900, 1, 1)..Date.current + 20.years).cover?(next_on)
  end

  def occurrence_on(index)
    return next_on + DAYS.fetch(frequency) * index unless MONTHS.key?(frequency)
    date = next_on.advance(months: MONTHS.fetch(frequency) * index)
    month_end? ? date.end_of_month : date
  end

  def next_occurrence(from = Date.current)
    return occurrence_on(0) if occurrence_on(0) >= from
    index = if MONTHS.key?(frequency)
      [((from.year * 12 + from.month) - (next_on.year * 12 + next_on.month)) / MONTHS.fetch(frequency), 0].max
    else
      ((from - next_on).to_i / DAYS.fetch(frequency))
    end
    index += 1 while occurrence_on(index) < from
    occurrence_on(index)
  end

  def occurrences(from:, to:)
    return [] unless status == "active" && from <= to && (account.nil? || account.tracked?)
    first = next_occurrence(from)
    index = MONTHS.key?(frequency) ? ((first.year * 12 + first.month) - (next_on.year * 12 + next_on.month)) / MONTHS.fetch(frequency) : (first - next_on).to_i / DAYS.fetch(frequency)
    dates = []
    while (date = occurrence_on(index)) <= to
      dates << date
      index += 1
    end
    dates
  end

  def account_label
    account&.name || source_account_name.presence || "No account specified"
  end

  def linked_history
    return [] if merchant_key.blank?
    scope = user.transactions.roots.visible_in_reports.where(iso_currency_code: currency, date: (Date.current - 3.years)..Date.current)
    scope = account_id ? scope.where(account_id: account_id) : scope.where(account_id: nil, source_account_name: source_account_name.presence || [nil, ""])
    scope.order(date: :desc, id: :desc).select { |transaction| transaction.merchant_key == merchant_key }.first(6)
  end
end
