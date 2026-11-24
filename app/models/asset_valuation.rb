class AssetValuation < ApplicationRecord
  belongs_to :manual_asset
  validates :value, :valued_on, presence: true
end
