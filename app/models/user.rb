class User < ApplicationRecord
  has_secure_password
  has_secure_token :session_token

  attr_accessor :current_password

  normalizes :email, with: ->(email) { email.strip.downcase }

  before_update :rotate_session_token, if: :will_save_change_to_password_digest?

  has_many :plaid_items, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :transactions, dependent: :destroy
  has_many :categories, dependent: :destroy
  has_many :category_expense_types, dependent: :destroy
  has_many :balance_snapshots, dependent: :destroy
  has_many :manual_assets, dependent: :destroy
  has_many :import_profiles, dependent: :destroy
  has_many :import_batches, dependent: :destroy
  has_many :transaction_rules, dependent: :destroy
  has_many :budgets, dependent: :destroy
  has_many :recurring_items, dependent: :destroy
  has_many :recurring_dismissals, dependent: :destroy

  validates :email, presence: true, uniqueness: { case_sensitive: false }

  private

  def rotate_session_token
    self.session_token = SecureRandom.base58(32)
  end
end
