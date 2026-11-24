class AddExpenseTypes < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :expense_type, :string
    add_check_constraint :transactions, "expense_type IS NULL OR expense_type IN ('fixed', 'variable', 'unclassified')", name: "valid_transaction_expense_type"
    create_table :category_expense_types do |t|
      t.references :user, null: false, foreign_key: true
      t.references :category, null: false, foreign_key: { on_delete: :cascade }
      t.string :expense_type, null: false
      t.timestamps
    end
    add_index :category_expense_types, [:user_id, :category_id], unique: true
    add_check_constraint :category_expense_types, "expense_type IN ('fixed', 'variable', 'unclassified')", name: "valid_category_expense_type"
  end
end
