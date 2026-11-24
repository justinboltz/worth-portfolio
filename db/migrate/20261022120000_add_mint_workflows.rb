class AddMintWorkflows < ActiveRecord::Migration[7.2]
  def change
    change_column_null :transactions, :account_id, true
    change_column_null :transactions, :plaid_item_id, true
    add_column :transactions, :source_account_name, :string
    add_column :transactions, :tags, :string, default: "", null: false
    %i[hidden duplicate transfer card_payment is_split].each { |flag| add_column :transactions, flag, :boolean, default: false, null: false }
    add_reference :transactions, :parent, foreign_key: { to_table: :transactions }
    create_table :import_profiles do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.jsonb :settings, default: {}, null: false
      t.timestamps
    end
    create_table :import_batches do |t|
      t.references :user, null: false, foreign_key: true
      t.text :csv_text, null: false
      t.jsonb :settings, default: {}, null: false
      t.datetime :imported_at
      t.timestamps
    end
    create_table :transaction_rules do |t|
      t.references :user, null: false, foreign_key: true
      t.references :category, foreign_key: true
      t.string :match_text, null: false
      t.string :kind, default: "regular", null: false
      t.string :tags, default: "", null: false
      t.timestamps
    end
    create_table :budgets do |t|
      t.references :user, null: false, foreign_key: true
      t.references :category, null: false, foreign_key: true
      t.decimal :amount, precision: 19, scale: 2, null: false
      t.string :currency, default: "USD", null: false
      t.date :starts_on, null: false
      t.boolean :rollover, default: false, null: false
      t.timestamps
    end
    add_index :budgets, [:user_id, :category_id], unique: true
  end
end
