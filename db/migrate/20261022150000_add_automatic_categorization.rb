class AddAutomaticCategorization < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :category_locked, :boolean, default: false, null: false
    add_column :transactions, :category_origin, :string
    add_column :transactions, :category_reason, :string
    add_column :transactions, :category_suggestion_reason, :string
    add_reference :transactions, :suggested_category, foreign_key: { to_table: :categories, on_delete: :nullify }
    add_column :transaction_rules, :merchant_key, :string
    add_index :transaction_rules, [:user_id, :merchant_key], unique: true, where: "merchant_key IS NOT NULL"
    reversible do |direction|
      direction.up { execute "UPDATE transactions SET category_locked = TRUE, category_origin = 'existing', category_reason = 'Your existing category was preserved' WHERE category_id IS NOT NULL" }
    end
  end
end
