require "test_helper"

class ManualAssetsTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []
  self.use_transactional_tests = true

  setup do
    @user = User.create!(email: "assets@example.com", password: "test-password")
    post sign_in_path, params: { email: @user.email, password: "test-password" }
  end

  test "create and update a manual asset while preserving valuations" do
    assert_difference "ManualAsset.count", 1 do
      post manual_assets_path, params: { manual_asset: { name: "Home", asset_type: "property", value: "300000", currency: "USD", valued_on: Date.yesterday } }
    end
    assert_redirected_to manual_assets_path
    asset = @user.manual_assets.last
    assert_equal 1, asset.asset_valuations.count
    patch manual_asset_path(asset), params: { manual_asset: { value: "310000", valued_on: Date.current } }
    assert_redirected_to manual_assets_path
    assert_equal 2, asset.asset_valuations.count
    assert_equal BigDecimal("310000"), asset.reload.value
    get root_path
    assert_response :success
    assert_select ".metric", text: /310,000.00/
  end

  test "reject invalid values and isolate assets by user" do
    post manual_assets_path, params: { manual_asset: { name: "Home", asset_type: "property", value: "-1", currency: "USD", valued_on: Date.current } }
    assert_response :unprocessable_entity
    other = User.create!(email: "other-assets@example.com", password: "test-password")
    asset = other.manual_assets.create!(name: "Private home", asset_type: "property", value: 100, currency: "USD", valued_on: Date.current)
    patch manual_asset_path(asset), params: { manual_asset: { value: "200" } }
    assert_response :not_found
    assert_equal BigDecimal("100"), asset.reload.value
  end
end
