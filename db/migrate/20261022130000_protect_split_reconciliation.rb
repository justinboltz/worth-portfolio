class ProtectSplitReconciliation < ActiveRecord::Migration[7.2]
  def change
    add_column :transactions, :split_needs_review, :boolean, default: false, null: false
  end
end
