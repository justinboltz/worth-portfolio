namespace :plaid do
  desc "Enqueue a sync for all active Plaid items"
  task sync_all: :environment do
    PlaidSyncAllJob.perform_later
  end

  desc "Sync all active Plaid items inline (no background queue)"
  task sync_all_inline: :environment do
    PlaidItem.status_active.find_each do |plaid_item|
      Plaid::SyncItem.call(plaid_item: plaid_item)
    end
  end
end
