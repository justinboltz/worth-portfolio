require "test_helper"

class FictionalDemoTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []
  test "local fictional demo omits Plaid's browser script and blocks link tokens" do
    previous_demo = ENV["WORTH_DEMO"]
    ENV["WORTH_DEMO"] = "1"
    user = User.create!(email: "fictional-demo@example.test", password: "test-password")
    post sign_in_path, params: { email: user.email, password: "test-password" }

    get new_bank_connection_path
    assert_response :success
    assert_select "h1", "Bank linking is off"
    assert_select "script[src*='cdn.plaid.com']", count: 0

    post api_v1_plaid_link_token_path
    assert_response 422
    assert_equal "plaid_not_configured", JSON.parse(response.body).fetch("error")
  ensure
    ENV["WORTH_DEMO"] = previous_demo
  end
end
