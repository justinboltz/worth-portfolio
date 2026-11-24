class CreateCategories < ActiveRecord::Migration[7.2]
  def change
    create_table :categories do |t|
      t.references :user, null: true, foreign_key: true
      t.references :parent, null: true, foreign_key: { to_table: :categories }
      t.string :name, null: false
      t.boolean :system, null: false, default: false

      t.timestamps
    end

    add_index :categories, %i[user_id parent_id name], unique: true
    add_index :categories, %i[parent_id name], unique: true, where: "user_id IS NULL"
  end
end
