class RecurringDismissal < ApplicationRecord
  belongs_to :user
  validates :detection_key, :name, presence: true
  validates :detection_key, uniqueness: { scope: :user_id }
end
