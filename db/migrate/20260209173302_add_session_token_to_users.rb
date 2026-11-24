require "securerandom"

class AddSessionTokenToUsers < ActiveRecord::Migration[7.2]
  class MigrationUser < ApplicationRecord
    self.table_name = "users"
  end

  def up
    add_column :users, :session_token, :string

    MigrationUser.reset_column_information

    MigrationUser.where(session_token: nil).find_each do |user|
      user.update_columns(session_token: SecureRandom.base58(32))
    end

    change_column_null :users, :session_token, false
    add_index :users, :session_token, unique: true
  end

  def down
    remove_index :users, :session_token
    remove_column :users, :session_token
  end
end
