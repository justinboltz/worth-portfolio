class PlaidSyncAllJob < ApplicationJob
  queue_as :default

  def perform
    PlaidItem.status_active.find_each do |plaid_item|
      plaid_item.request_sync
    end
  end
end
