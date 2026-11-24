module PlaidApi
  class Error < StandardError
    attr_reader :http_status, :error_type, :error_code, :request_id, :display_message, :documentation_url

    def initialize(message, http_status: nil, error_type: nil, error_code: nil, request_id: nil, display_message: nil,
                   documentation_url: nil)
      super(message)
      @http_status = http_status
      @error_type = error_type
      @error_code = error_code
      @request_id = request_id
      @display_message = display_message
      @documentation_url = documentation_url
    end

    def to_h
      {
        http_status: http_status,
        error_type: error_type,
        error_code: error_code,
        request_id: request_id,
        display_message: display_message,
        documentation_url: documentation_url
      }.compact
    end
  end
end
