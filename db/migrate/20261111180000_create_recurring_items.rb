class CreateRecurringItems < ActiveRecord::Migration[7.2]
  def change
    create_table :recurring_items do |t|
      t.references :user, null: false, foreign_key: true
      t.references :account, foreign_key: { on_delete: :nullify }
      t.string :name, null: false
      t.decimal :amount, precision: 14, scale: 4, null: false
      t.string :currency, null: false, default: "USD"
      t.string :direction, null: false, default: "expense"
      t.string :frequency, null: false, default: "monthly"
      t.date :next_on, null: false
      t.boolean :month_end, null: false, default: false
      t.string :status, null: false, default: "active"
      t.string :merchant_key
      t.string :source_account_name
      t.string :detection_key
      t.text :notes
      t.timestamps
    end
    add_index :recurring_items, [:user_id, :detection_key], unique: true
    add_check_constraint :recurring_items, "amount > 0", name: "recurring_amount_positive"
    create_table :recurring_dismissals do |t|
      t.references :user, null: false, foreign_key: true
      t.string :detection_key, null: false
      t.string :name, null: false
      t.timestamps
    end
    add_index :recurring_dismissals, [:user_id, :detection_key], unique: true
  end
end
