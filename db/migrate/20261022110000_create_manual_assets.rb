class CreateManualAssets < ActiveRecord::Migration[7.2]
  def change
    create_table :manual_assets do |table|
      table.references :user, null: false, foreign_key: true
      table.string :name, null: false
      table.string :asset_type, null: false
      table.decimal :value, precision: 19, scale: 2, null: false
      table.string :currency, null: false, default: "USD"
      table.date :valued_on, null: false
      table.text :notes
      table.timestamps
    end

    create_table :asset_valuations do |table|
      table.references :manual_asset, null: false, foreign_key: true
      table.decimal :value, precision: 19, scale: 2, null: false
      table.date :valued_on, null: false
      table.timestamps
    end
    add_index :asset_valuations, [:manual_asset_id, :valued_on], unique: true
  end
end
