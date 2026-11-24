class Account < ApplicationRecord
  belongs_to :user
  belongs_to :plaid_item, optional: true

  has_many :transactions, dependent: :destroy
  has_many :balance_snapshots, dependent: :destroy

  scope :tracked, -> { where(tracked: true) }
  scope :in_net_worth, -> { tracked.where(net_worth_excluded: false) }

  validates :plaid_account_id, presence: true, unless: :import_source_key?
  validates :plaid_account_id, uniqueness: true, allow_nil: true
  validates :plaid_item, presence: true, unless: :import_source_key?
  validates :import_source_key, uniqueness: { scope: :user_id }, allow_nil: true
  validates :name, presence: true
  validates :account_type, presence: true
end
