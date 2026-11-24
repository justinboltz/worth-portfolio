class AddTillerImports < ActiveRecord::Migration[7.2]
  def change
    change_column_null :accounts, :plaid_item_id, true
    change_column_null :accounts, :plaid_account_id, true
    add_column :accounts, :import_source_key, :string
    add_column :accounts, :import_metadata, :jsonb, default: {}, null: false
    add_column :accounts, :net_worth_excluded, :boolean, default: false, null: false
    add_index :accounts, [:user_id, :import_source_key], unique: true, where: "import_source_key IS NOT NULL"
    add_check_constraint :accounts, "(plaid_item_id IS NOT NULL AND plaid_account_id IS NOT NULL) OR import_source_key IS NOT NULL", name: "accounts_have_a_source"
    add_column :balance_snapshots, :import_metadata, :jsonb, default: {}, null: false
  end
end
