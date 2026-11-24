class BankConnectionsController < ApplicationController
  before_action :require_authentication

  def new
    render :demo_disabled if ENV["WORTH_DEMO"] == "1"
  end
end
