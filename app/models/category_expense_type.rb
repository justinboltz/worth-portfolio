class CategoryExpenseType < ApplicationRecord
  belongs_to :user
  belongs_to :category
  validates :category_id, uniqueness: { scope: :user_id }
  validates :expense_type, inclusion: { in: ExpenseClassification::LABELS.keys }
  validate do
    errors.add(:category, "is unavailable") if category && !(category.system? || category.user_id == user_id)
  end
end
