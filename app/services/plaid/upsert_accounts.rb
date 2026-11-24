module Plaid
  class UpsertAccounts
    def self.call(user:, plaid_item:, accounts:)
      accounts.map do |account|
        account_id = account.fetch("account_id")
        balances = account.fetch("balances", {})

        record = user.accounts.find_or_initialize_by(plaid_account_id: account_id)
        record.plaid_item = plaid_item
        record.name = account.fetch("name")
        record.official_name = account["official_name"]
        record.account_type = account.fetch("type")
        record.subtype = account["subtype"]
        record.mask = account["mask"]
        record.iso_currency_code = balances["iso_currency_code"] || balances["unofficial_currency_code"]
        record.current_balance = balances["current"]
        record.available_balance = balances["available"]
        record.limit_balance = balances["limit"]
        record.save!
        if record.current_balance.present?
          snapshot = user.balance_snapshots.find_or_initialize_by(account: record, as_of_date: Date.current)
          snapshot.update!(current_balance: record.current_balance, available_balance: record.available_balance, iso_currency_code: record.iso_currency_code)
        end
        record
      end
    end
  end
end
