class PlaidItem < ApplicationRecord
  belongs_to :user
  belongs_to :institution

  has_many :accounts, dependent: :destroy
  has_many :transactions, dependent: :destroy

  encrypts :access_token

  validates :plaid_item_id, presence: true, uniqueness: true
  validates :access_token, presence: true
  validates :status, presence: true

  SYNC_LEASE = 20.minutes
  SyncRequest = Struct.new(:status, :job_id, keyword_init: true)

  def sync_in_progress?(now: Time.current)
    sync_requested_at.present? && sync_requested_at > now - SYNC_LEASE
  end

  def stale?(now: Time.current)
    last_synced_at.nil? || last_synced_at < now - 1.hour
  end

  def claim_sync(token:, stale_only: false)
    return :busy if reload.sync_in_progress?
    with_lock do
      return :busy if sync_in_progress?
      return :fresh if stale_only && !stale?
      update!(sync_requested_at: Time.current, sync_request_token: token)
    end
    :claimed
  end

  def release_sync(token)
    self.class.where(id: id, sync_request_token: token).update_all(sync_requested_at: nil, sync_request_token: nil)
  end

  def request_sync(stale_only: false)
    job = PlaidSyncItemJob.new(id)
    result = claim_sync(token: job.job_id, stale_only: stale_only)
    return SyncRequest.new(status: result) unless result == :claimed
    job.arguments = [id, job.job_id]
    if job.enqueue
      SyncRequest.new(status: :enqueued, job_id: job.job_id)
    else
      release_sync(job.job_id)
      SyncRequest.new(status: :failed)
    end
  rescue StandardError => error
    release_sync(job.job_id) if job && result == :claimed
    Rails.logger.error("Plaid sync enqueue failed for item #{id}: #{error.class}")
    SyncRequest.new(status: :failed)
  end

  enum :status, { active: "active", errored: "errored" }, prefix: true
end
