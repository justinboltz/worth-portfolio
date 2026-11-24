class ImportBatch < ApplicationRecord
  belongs_to :user
  validates :csv_text, presence: true, length: { maximum: ->(batch) { batch.tiller? ? 30.megabytes : 5.megabytes } }

  def tiller?
    settings["format"] == "tiller"
  end
end
