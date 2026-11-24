class ManualAsset < ApplicationRecord
  TYPES = { "property" => "Real estate", "vehicle" => "Vehicle", "other" => "Other asset" }.freeze

  belongs_to :user
  has_many :asset_valuations, dependent: :destroy

  validates :name, :valued_on, presence: true
  validates :asset_type, inclusion: { in: TYPES.keys }
  validates :currency, inclusion: { in: %w[USD CAD EUR GBP] }
  validates :value, numericality: { greater_than_or_equal_to: 0, less_than: 100_000_000_000_000_000 }
  validate :valuation_date_is_valid

  after_save :record_valuation

  private

  def valuation_date_is_valid
    errors.add(:valued_on, "cannot be in the future") if valued_on && valued_on > Date.current
    if persisted? && valued_on && valued_on_in_database && valued_on < valued_on_in_database
      errors.add(:valued_on, "cannot be earlier than the current valuation")
    end
  end

  def record_valuation
    valuation = asset_valuations.find_or_initialize_by(valued_on: valued_on)
    valuation.update!(value: value)
  end
end
