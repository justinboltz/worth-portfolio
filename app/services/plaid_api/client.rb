require "json"
require "faraday"

module PlaidApi
  class Client
    PLAID_VERSION = "2020-09-14"

    ENV_TO_BASE_URL = {
      "sandbox" => "https://sandbox.plaid.com",
      "development" => "https://development.plaid.com",
      "production" => "https://production.plaid.com"
    }.freeze

    def self.from_env
      raise KeyError, "Bank linking is unavailable in the fictional demo" if ENV["WORTH_DEMO"] == "1"

      new(
        client_id: ENV["PLAID_CLIENT_ID"].presence || Rails.application.credentials.dig(:plaid, :client_id) || raise(KeyError, "Run bin/rails plaid:configure first"),
        secret: ENV["PLAID_SECRET"].presence || Rails.application.credentials.dig(:plaid, :secret) || raise(KeyError, "Run bin/rails plaid:configure first"),
        env: ENV["PLAID_ENV"].presence || Rails.application.credentials.dig(:plaid, :env) || "sandbox"
      )
    end

    def initialize(client_id:, secret:, env:)
      @client_id = client_id
      @secret = secret
      @env = env

      base_url = ENV_TO_BASE_URL.fetch(@env) do
        raise ArgumentError, "Unsupported PLAID_ENV=#{@env.inspect}. Expected one of: #{ENV_TO_BASE_URL.keys.join(", ")}"
      end

      @connection = Faraday.new(url: base_url) do |faraday|
        faraday.adapter Faraday.default_adapter
      end
    end

    def create_link_token(user:, client_name:, products:, country_codes:, language:, webhook: nil, redirect_uri: nil,
                          transactions_days_requested: nil)
      body = {
        client_name: client_name,
        user: { client_user_id: user.id.to_s },
        products: products,
        country_codes: country_codes,
        language: language
      }

      body[:webhook] = webhook if webhook.present?
      body[:redirect_uri] = redirect_uri if redirect_uri.present?
      if transactions_days_requested.present?
        body[:transactions] = { days_requested: transactions_days_requested }
      end

      post_json("/link/token/create", body).fetch("link_token")
    end

    def exchange_public_token(public_token:)
      post_json("/item/public_token/exchange", { public_token: public_token })
    end

    def accounts_get(access_token:)
      post_json("/accounts/get", { access_token: access_token })
    end

    def transactions_sync(access_token:, cursor: nil, count: 500)
      body = { access_token: access_token, count: count }
      body[:cursor] = cursor if cursor.present?
      post_json("/transactions/sync", body)
    end

    private

    def post_json(path, body)
      response = @connection.post(path) do |request|
        request.headers["Content-Type"] = "application/json"
        request.headers["Plaid-Version"] = PLAID_VERSION
        request.body = JSON.dump(body.merge(client_id: @client_id, secret: @secret))
      end

      parsed = parse_json(response.body)

      if response.status >= 400 || (parsed.is_a?(Hash) && parsed["error_code"].present?)
        raise build_error(parsed, http_status: response.status)
      end

      parsed
    rescue Faraday::Error => e
      raise Error.new("Plaid connection error: #{e.message}")
    end

    def parse_json(json_string)
      JSON.parse(json_string.to_s)
    rescue JSON::ParserError
      {}
    end

    def build_error(parsed_body, http_status:)
      error_message = parsed_body.is_a?(Hash) ? parsed_body["error_message"] : nil

      Error.new(
        error_message.presence || "Plaid API error",
        http_status: http_status,
        error_type: parsed_body["error_type"],
        error_code: parsed_body["error_code"],
        request_id: parsed_body["request_id"],
        display_message: parsed_body["display_message"],
        documentation_url: parsed_body["documentation_url"]
      )
    end
  end
end
