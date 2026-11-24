module Api
  module V1
    class PlaidController < BaseController
      before_action :require_authentication

      def link_token
        client = PlaidApi::Client.from_env

        link_token = client.create_link_token(
          user: current_user,
          client_name: ENV.fetch("PLAID_CLIENT_NAME", "Worth"),
          products: ENV.fetch("PLAID_PRODUCTS", "transactions").split(",").map(&:strip),
          country_codes: ENV.fetch("PLAID_COUNTRY_CODES", "US").split(",").map(&:strip),
          language: ENV.fetch("PLAID_LANGUAGE", "en"),
          transactions_days_requested: Integer(ENV.fetch("PLAID_TRANSACTIONS_DAYS_REQUESTED", "730"))
        )

        render json: { link_token: link_token }
      rescue KeyError => e
        render json: { error: "plaid_not_configured", message: e.message }, status: :unprocessable_entity
      rescue PlaidApi::Error => e
        render json: { error: "plaid_error", message: e.message, plaid: e.to_h }, status: :bad_gateway
      end

      def exchange_public_token
        public_token = params.require(:public_token)
        institution_id = params.require(:institution_id)
        institution_name = params[:institution_name]

        client = PlaidApi::Client.from_env
        exchange = client.exchange_public_token(public_token: public_token)

        plaid_item_id = exchange.fetch("item_id")
        access_token = exchange.fetch("access_token")

        institution = Institution.find_or_initialize_by(plaid_institution_id: institution_id)
        institution.name = institution_name.presence || institution.name || institution_id
        institution.save!

        existing_item = PlaidItem.find_by(plaid_item_id: plaid_item_id)
        if existing_item.present? && existing_item.user_id != current_user.id
          return render json: { error: "item_already_linked" }, status: :conflict
        end

        plaid_item = current_user.plaid_items.find_or_initialize_by(plaid_item_id: plaid_item_id)
        plaid_item.institution = institution
        plaid_item.access_token = access_token
        plaid_item.status = "active"
        plaid_item.save!

        accounts_response = client.accounts_get(access_token: access_token)
        accounts = accounts_response.fetch("accounts")
        Plaid::UpsertAccounts.call(user: current_user, plaid_item: plaid_item, accounts: accounts)

        plaid_item.request_sync()

        render json: { plaid_item: { id: plaid_item.id }, accounts: accounts.size }
      rescue ActionController::ParameterMissing => e
        render json: { error: "bad_request", message: e.message }, status: :bad_request
      rescue KeyError => e
        render json: { error: "plaid_not_configured", message: e.message }, status: :unprocessable_entity
      rescue PlaidApi::Error => e
        render json: { error: "plaid_error", message: e.message, plaid: e.to_h }, status: :bad_gateway
      end

      def sync_item
        plaid_item = current_user.plaid_items.find(params[:id])
        async = ActiveModel::Type::Boolean.new.cast(params.fetch(:async, true))

        if async
          request = plaid_item.request_sync
          return render json: { enqueued: request.status == :enqueued, status: request.status, job_id: request.job_id, plaid_item: { id: plaid_item.id } }, status: request.status == :failed ? :service_unavailable : :accepted
        end

        token = SecureRandom.uuid
        if plaid_item.claim_sync(token: token) == :busy
          return render json: { error: "sync_in_progress", message: "A refresh is already queued or running." }, status: :conflict
        end
        begin
          result = Plaid::SyncItem.call(plaid_item: plaid_item)
        ensure
          plaid_item.release_sync(token)
        end
        render json: {
          plaid_item: { id: plaid_item.id, last_synced_at: plaid_item.last_synced_at },
          added: result.added,
          modified: result.modified,
          removed: result.removed
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "not_found" }, status: :not_found
      rescue KeyError => e
        render json: { error: "plaid_not_configured", message: e.message }, status: :unprocessable_entity
      rescue PlaidApi::Error => e
        render json: { error: "plaid_error", message: e.message, plaid: e.to_h }, status: :bad_gateway
      end
    end
  end
end
