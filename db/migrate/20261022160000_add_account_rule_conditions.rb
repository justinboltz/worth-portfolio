class AddAccountRuleConditions < ActiveRecord::Migration[7.2]
  def change
    add_reference :transaction_rules, :account, foreign_key: { on_delete: :cascade }
    add_column :transaction_rules, :source_account_name, :string
    add_column :transaction_rules, :description_operator, :string, default: "contains", null: false
    add_column :transaction_rules, :effective_from, :datetime
    change_column_null :transaction_rules, :match_text, true
    reversible do |direction|
      direction.up { execute "UPDATE transaction_rules SET effective_from = created_at" }
      direction.down { execute "UPDATE transaction_rules SET match_text = '' WHERE match_text IS NULL" }
    end
  end
end
