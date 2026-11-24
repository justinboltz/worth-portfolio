class CreatePlaidItems < ActiveRecord::Migration[7.2]
  def change
    create_table :plaid_items do |t|
      t.references :user, null: false, foreign_key: true
      t.references :institution, null: false, foreign_key: true
      t.string :plaid_item_id, null: false
      t.text :access_token, null: false
      t.string :cursor
      t.string :status, null: false, default: "active"
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :plaid_items, :plaid_item_id, unique: true
  end
end
