class AddCashFlowClassification < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :classification_override, :boolean, default: false, null: false
    add_column :transactions, :classification_origin, :string
    add_column :transactions, :classification_reason, :string
    add_column :transactions, :suggested_classification, :string
    add_column :transactions, :suggestion_reason, :string
    add_reference :transactions, :matched_transaction, foreign_key: { to_table: :transactions, on_delete: :nullify }
    reversible do |direction|
      direction.up { execute "UPDATE transactions SET classification_override = TRUE, classification_origin = 'manual' WHERE transfer = TRUE OR card_payment = TRUE" }
    end
  end
end
