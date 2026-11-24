class CreateBalanceSnapshots < ActiveRecord::Migration[7.2]
  def change
    create_table :balance_snapshots do |t|
      t.references :user, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.date :as_of_date, null: false
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.string :iso_currency_code

      t.timestamps
    end

    add_index :balance_snapshots, %i[account_id as_of_date], unique: true
  end
end
