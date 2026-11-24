class BalanceSnapshot < ApplicationRecord
  belongs_to :user
  belongs_to :account

  validates :as_of_date, presence: true, uniqueness: { scope: :account_id }
end
