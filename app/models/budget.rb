class Budget < ApplicationRecord
  belongs_to :user
  belongs_to :category
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :starts_on, presence: true
  validates :currency, inclusion: { in: %w[USD CAD EUR GBP] }
  validates :category_id, uniqueness: { scope: :user_id }
  before_validation { self.starts_on = starts_on.beginning_of_month if starts_on }
  validate do
    errors.add(:category, "is unavailable") if category && !(category.system? || category.user_id == user_id)
    if category && user
      overlap = user.budgets.where.not(id: id).includes(:category).any? { |b| (b.category.subtree_ids & category.subtree_ids).any? }
      errors.add(:category, "overlaps an existing parent or child budget") if overlap
    end
  end
  def spending(month)
    spending_scope.where(date: month.beginning_of_month..month.end_of_month).sum(:amount)
  end
  def available(month)
    return 0.to_d if month < starts_on
    return amount unless rollover?
    months = (month.year * 12 + month.month) - (starts_on.year * 12 + starts_on.month)
    amount * (months + 1) - spending_scope.where(date: starts_on...month.beginning_of_month).sum(:amount)
  end
  def spending_scope
    user.transactions.reportable.where(category_id: category.subtree_ids, iso_currency_code: currency).where("amount > 0")
  end
end
