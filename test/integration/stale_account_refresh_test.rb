require "test_helper"
require "minitest/mock"

class StaleAccountRefreshTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  self.fixture_table_names = []

  setup do
    @user = User.create!(email: 'refresh@example.test', password: 'test-password')
    @bank = Institution.create!(name: 'Refresh Bank', plaid_institution_id: 'refresh-bank')
    post sign_in_path, params: { email: @user.email, password: 'test-password' }
  end

  def item(**attributes)
    @user.plaid_items.create!({ institution: @bank, plaid_item_id: SecureRandom.uuid, access_token: 'fake-test-token' }.merge(attributes))
  end

  test "only stale or never synced owned connections enqueue and repeated clicks do not duplicate work" do
    travel_to Time.zone.local(2026, 11, 11, 12) do
      old = item(last_synced_at: 61.minutes.ago)
      never = item
      errored = item(last_synced_at: 2.hours.ago, status: 'errored')
      recent = item(last_synced_at: 59.minutes.ago)
      boundary = item(last_synced_at: 1.hour.ago)
      busy = item(sync_requested_at: 1.minute.ago, sync_request_token: 'in-flight')
      other = User.create!(email: 'other-refresh@example.test', password: 'test-password')
      private_item = other.plaid_items.create!(institution: @bank, plaid_item_id: SecureRandom.uuid, access_token: 'fake-test-token', last_synced_at: 2.days.ago)
      PlaidApi::Client.stub(:from_env, -> { raise 'No provider calls allowed' }) do
        assert_enqueued_jobs 3, only: PlaidSyncItemJob do
          post refresh_stale_plaid_items_path
          assert_redirected_to root_path
        end
        assert_enqueued_jobs 0 do
          post refresh_stale_plaid_items_path
          post sync_plaid_item_path(old)
        end
      end
      assert [old, never, errored].all? { |connection| connection.reload.sync_in_progress? }
      assert [recent, boundary, private_item].all? { |connection| connection.reload.sync_request_token.nil? }
      assert_equal 'in-flight', busy.reload.sync_request_token
      assert_equal 61.minutes.ago, old.last_synced_at
      post sync_plaid_item_path(private_item)
      assert_response :not_found
    end
  end

  test "worker releases the claim on success and failure and rejects superseded jobs" do
    connection = item(last_synced_at: 2.hours.ago)
    request = connection.request_sync
    assert_equal :enqueued, request.status
    calls = 0
    Plaid::SyncItem.stub(:call, ->(plaid_item:, **_) { calls += 1; plaid_item.update!(last_synced_at: Time.current) }) do
      PlaidSyncItemJob.perform_now(connection.id, request.job_id)
      PlaidSyncItemJob.perform_now(connection.id, request.job_id)
    end
    assert_equal 1, calls
    assert_nil connection.reload.sync_request_token
    assert_in_delta Time.current.to_f, connection.last_synced_at.to_f, 2
    next_request = connection.request_sync
    Plaid::SyncItem.stub(:call, ->(**_) { raise PlaidApi::Error, 'Mock provider unavailable' }) do
      assert_raises(PlaidApi::Error) { PlaidSyncItemJob.perform_now(connection.id, next_request.job_id) }
    end
    assert_nil connection.reload.sync_requested_at
    assert_equal :enqueued, connection.request_sync.status
  end

  test "abandoned queue claims can be replaced and old jobs cannot clear new claims" do
    connection = item(sync_requested_at: 21.minutes.ago, sync_request_token: 'abandoned')
    request = connection.request_sync(stale_only: true)
    assert_equal :enqueued, request.status
    Plaid::SyncItem.stub(:call, ->(**_) { raise 'Superseded job must not call provider' }) do
      PlaidSyncItemJob.perform_now(connection.id, 'abandoned')
    end
    assert_equal request.job_id, connection.reload.sync_request_token
  end

  test "enqueue failure releases claim and shows an actionable result" do
    connection = item
    job = PlaidSyncItemJob.new(connection.id)
    job.stub(:enqueue, false) do
      PlaidSyncItemJob.stub(:new, job) do
        post refresh_stale_plaid_items_path
        assert_redirected_to root_path
        assert_match(/could not be queued/, flash[:alert])
      end
    end
    assert_nil connection.reload.sync_requested_at
  end

  test "dashboard explains staleness and disables a queued connection" do
    connection = item(sync_requested_at: Time.current, sync_request_token: 'queued')
    get root_path
    assert_response :success
    assert_select "form[action='#{refresh_stale_plaid_items_path}'] button", text: 'Refresh stale accounts'
    assert_select "form[action='#{sync_plaid_item_path(connection)}'] button[disabled]"
    assert_select 'a', text: 'Check refresh status'
  end
  test "provider success advances freshness but failure preserves the last successful time" do
    connection = item(last_synced_at: 2.hours.ago)
    client = Object.new
    def client.accounts_get(**); { "accounts" => [] }; end
    def client.transactions_sync(**)
      { "added" => [], "modified" => [], "removed" => [], "next_cursor" => "test-cursor", "has_more" => false }
    end
    request = connection.request_sync
    PlaidApi::Client.stub(:from_env, client) { PlaidSyncItemJob.perform_now(connection.id, request.job_id) }
    assert connection.reload.status_active?
    assert_not connection.stale?
    successful_time = connection.last_synced_at
    request = connection.request_sync
    client.stub(:accounts_get, ->(**_) { raise PlaidApi::Error, "Test bank unavailable" }) do
      PlaidApi::Client.stub(:from_env, client) do
        assert_raises(PlaidApi::Error) { PlaidSyncItemJob.perform_now(connection.id, request.job_id) }
      end
    end
    assert connection.reload.status_errored?
    assert_equal successful_time, connection.last_synced_at
    assert_nil connection.sync_requested_at
  end

  test "existing sync all continues to request active connections even if recent" do
    recent = item(last_synced_at: 5.minutes.ago)
    errored = item(status: 'errored')
    assert_enqueued_jobs 1, only: PlaidSyncItemJob do
      PlaidSyncAllJob.perform_now
    end
    assert recent.reload.sync_in_progress?
    assert_nil errored.reload.sync_requested_at
  end

end
