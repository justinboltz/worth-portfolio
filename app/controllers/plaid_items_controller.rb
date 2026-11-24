class PlaidItemsController < ApplicationController
  before_action :require_authentication

  def sync
    item = current_user.plaid_items.find(params[:id])
    result = item.request_sync
    if result.status == :failed
      redirect_to root_path, alert: "Could not queue the refresh. Please try again."
    else
      message = result.status == :busy ? "A refresh is already queued or running for #{item.institution.name}." : "Refresh queued for #{item.institution.name}."
      redirect_to root_path, notice: message
    end
  end

  def refresh_stale
    counts = Hash.new(0)
    current_user.plaid_items.find_each { |item| counts[item.request_sync(stale_only: true).status] += 1 }
    notice = if counts[:enqueued].positive?
      "Refresh queued for #{counts[:enqueued]} #{'bank connection'.pluralize(counts[:enqueued])}."
    elsif counts[:failed].positive?
      "No refreshes were queued."
    else
      "No refresh needed. Connections are up to date or already queued."
    end
    notice += " #{counts[:busy]} already queued or refreshing." if counts[:busy].positive?
    flash[:alert] = "#{counts[:failed]} #{'connection'.pluralize(counts[:failed])} could not be queued. Please try again." if counts[:failed].positive?
    redirect_to root_path, notice: notice
  end

  def tracking
    item = current_user.plaid_items.find(params[:id])
    selected_ids = Array(params[:account_ids]).reject(&:blank?).map(&:to_s).uniq
    item.with_lock do
      accounts = item.accounts.where(user: current_user).to_a
      raise ActiveRecord::RecordNotFound unless (selected_ids - accounts.map { |account| account.id.to_s }).empty?
      accounts.each { |account| account.update!(tracked: selected_ids.include?(account.id.to_s)) }
    end
    redirect_to root_path, notice: "Account tracking updated. Saved history is preserved."
  end
end
