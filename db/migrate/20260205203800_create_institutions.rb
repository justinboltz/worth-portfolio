class CreateInstitutions < ActiveRecord::Migration[7.2]
  def change
    create_table :institutions do |t|
      t.string :name, null: false
      t.string :plaid_institution_id, null: false

      t.timestamps
    end

    add_index :institutions, :plaid_institution_id, unique: true
  end
end
