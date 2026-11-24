class Category < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :parent, class_name: "Category", optional: true

  has_many :children, class_name: "Category", foreign_key: :parent_id, dependent: :destroy, inverse_of: :parent
  has_many :transactions, dependent: :nullify
  has_many :category_expense_types, dependent: :destroy

  scope :for_user, ->(user) { where(system: true).or(where(user: user)) }

  validates :name, presence: true, uniqueness: { scope: %i[user_id parent_id] }

  def subtree_ids
    [id] + children.flat_map(&:subtree_ids)
  end

  def root_category
    parent ? parent.root_category : self
  end

  validate do
    errors.add(:parent, "is unavailable") if parent && !(parent.system? || parent.user_id == user_id)
    errors.add(:parent, "cannot be a descendant") if persisted? && parent_id && subtree_ids.include?(parent_id)
  end

  def display_name
    parent.present? ? "#{parent.name} > #{name}" : name
  end
end
