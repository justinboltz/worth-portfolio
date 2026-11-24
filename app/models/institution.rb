class Institution < ApplicationRecord
  has_many :plaid_items, dependent: :destroy

  validates :name, presence: true
  validates :plaid_institution_id, presence: true, uniqueness: true
end
