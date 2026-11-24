class CreateAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :accounts do |t|
      t.references :user, null: false, foreign_key: true
      t.references :plaid_item, null: false, foreign_key: true
      t.string :plaid_account_id, null: false
      t.string :name, null: false
      t.string :official_name
      t.string :account_type, null: false
      t.string :subtype
      t.string :mask
      t.string :iso_currency_code
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.decimal :limit_balance, precision: 19, scale: 4

      t.timestamps
    end

    add_index :accounts, :plaid_account_id, unique: true
  end
end
