class AddAccountTrackingAndSyncRequests < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :tracked, :boolean, null: false, default: true
    add_column :plaid_items, :sync_requested_at, :datetime
    add_column :plaid_items, :sync_request_token, :string
  end
end
