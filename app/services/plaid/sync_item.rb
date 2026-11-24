module Plaid
  class SyncItem
    MUTATION_DURING_PAGINATION_ERROR_CODE = "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION"

    Result = Struct.new(:added, :modified, :removed, :next_cursor, keyword_init: true)

    def self.call(plaid_item:, client: PlaidApi::Client.from_env, request_token: nil)
      new(plaid_item: plaid_item, client: client, request_token: request_token).call
    end

    def initialize(plaid_item:, client:, request_token: nil)
      @request_token = request_token
      @plaid_item = plaid_item
      @client = client
    end

    def call
      @plaid_item.with_lock do
        return if @request_token && @plaid_item.sync_request_token != @request_token
        refresh_accounts!
        sync_transactions!
      end
    rescue PlaidApi::Error
      @plaid_item.update!(status: "errored")
      raise
    end

    private

    def refresh_accounts!
      response = @client.accounts_get(access_token: @plaid_item.access_token)
      Plaid::UpsertAccounts.call(user: @plaid_item.user, plaid_item: @plaid_item, accounts: response.fetch("accounts"))
    end

    def sync_transactions!
      start_cursor = @plaid_item.cursor
      attempts = 0

      begin
        attempts += 1
        result = sync_transactions_from_cursor!(start_cursor: start_cursor)

        CashFlowClassifier.call(user: @plaid_item.user)
        AutoCategorizer.call(user: @plaid_item.user)
        @plaid_item.update!(
          cursor: result.next_cursor,
          last_synced_at: Time.current,
          status: "active"
        )

        result
      rescue PlaidApi::Error => e
        retry if e.error_code == MUTATION_DURING_PAGINATION_ERROR_CODE && attempts < 2
        raise
      end
    end

    def sync_transactions_from_cursor!(start_cursor:)
      cursor = start_cursor
      added_count = 0
      modified_count = 0
      removed_count = 0

      loop do
        response = @client.transactions_sync(access_token: @plaid_item.access_token, cursor: cursor)

        added = response.fetch("added")
        modified = response.fetch("modified")
        removed = response.fetch("removed")

        Plaid::UpsertTransactions.call(user: @plaid_item.user, plaid_item: @plaid_item, transactions: added)
        Plaid::UpsertTransactions.call(user: @plaid_item.user, plaid_item: @plaid_item, transactions: modified)

        removed_ids = removed.map { |removed_txn| removed_txn["transaction_id"] }.compact
        if removed_ids.any?
          @plaid_item.user.transactions.where(plaid_transaction_id: removed_ids).destroy_all
        end

        added_count += added.size
        modified_count += modified.size
        removed_count += removed_ids.size

        cursor = response.fetch("next_cursor")
        break unless response.fetch("has_more")
      end

      Result.new(added: added_count, modified: modified_count, removed: removed_count, next_cursor: cursor)
    end
  end
end
