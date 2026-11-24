module Plaid
  class UpsertTransactions
    def self.call(user:, plaid_item:, transactions:)
      transactions.each do |transaction|
        upsert_one(user: user, plaid_item: plaid_item, payload: transaction)
      end
      CashFlowClassifier.call(user: user)
      AutoCategorizer.call(user: user)
    end

    def self.upsert_one(user:, plaid_item:, payload:)
      transaction_id = payload.fetch("transaction_id")
      account_id = payload.fetch("account_id")

      account = user.accounts.find_by!(plaid_account_id: account_id)

      record = user.transactions.find_by(plaid_transaction_id: transaction_id)
      if record.blank? && payload["pending_transaction_id"].present?
        record = user.transactions.find_by(plaid_transaction_id: payload["pending_transaction_id"])
      end

      record ||= user.transactions.new

      record.plaid_item = plaid_item
      record.account = account
      record.plaid_transaction_id = transaction_id
      record.source = "plaid"
      record.source_transaction_id = nil
      record.pending = payload.fetch("pending", false)
      record.amount = payload.fetch("amount")
      record.iso_currency_code = payload["iso_currency_code"] || payload["unofficial_currency_code"]
      record.date = payload.fetch("date")
      record.authorized_date = payload["authorized_date"]
      record.name = payload["name"].presence || payload["merchant_name"].presence || "Transaction"
      record.merchant_name = payload["merchant_name"]
      record.merchant_entity_id = payload["merchant_entity_id"]
      record.payment_channel = payload["payment_channel"]
      record.pending_transaction_id = payload["pending_transaction_id"]
      record.original_description = payload["original_description"]
      record.raw_payload = payload

      record.split_needs_review = true if record.persisted? && record.is_split? && record.amount_changed?
      record.save!
      if record.is_split?
        record.splits.update_all(date: record.date, iso_currency_code: record.iso_currency_code)
      end
    end
  end
end
