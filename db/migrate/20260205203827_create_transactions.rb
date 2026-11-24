class CreateTransactions < ActiveRecord::Migration[7.2]
  def change
    create_table :transactions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.references :plaid_item, null: false, foreign_key: true
      t.references :category, null: true, foreign_key: true
      t.string :plaid_transaction_id
      t.string :source, null: false, default: "plaid"
      t.string :source_transaction_id
      t.boolean :pending, null: false, default: false
      t.decimal :amount, null: false, precision: 19, scale: 4
      t.string :iso_currency_code
      t.date :date, null: false
      t.date :authorized_date
      t.string :name, null: false
      t.string :merchant_name
      t.string :merchant_entity_id
      t.string :payment_channel
      t.string :pending_transaction_id
      t.string :original_description
      t.text :notes
      t.jsonb :raw_payload

      t.timestamps
    end

    add_index :transactions, %i[user_id plaid_transaction_id], unique: true, where: "plaid_transaction_id IS NOT NULL"
    add_index :transactions, %i[user_id source source_transaction_id], unique: true, where: "source_transaction_id IS NOT NULL"
    add_index :transactions, %i[account_id date]
  end
end
