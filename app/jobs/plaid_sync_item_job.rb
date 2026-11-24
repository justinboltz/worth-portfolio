class PlaidSyncItemJob < ApplicationJob
  queue_as :default

  def perform(plaid_item_id, request_token = nil)
    plaid_item = PlaidItem.find_by(id: plaid_item_id)
    return unless plaid_item
    token = request_token || job_id
    if request_token
      return unless plaid_item.sync_request_token == token
    else
      return unless plaid_item.claim_sync(token: token) == :claimed
    end
    begin
      Plaid::SyncItem.call(plaid_item: plaid_item, request_token: token)
    ensure
      plaid_item.release_sync(token)
    end
  end
end
