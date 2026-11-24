class ManualAssetsController < ApplicationController
  before_action :require_authentication
  before_action :find_asset, only: %i[edit update]

  def index
    @assets = current_user.manual_assets.order(:asset_type, :name)
    if params[:q].present?
      pattern = "%#{ManualAsset.sanitize_sql_like(params[:q].strip)}%"
      @assets = @assets.where("name ILIKE :term OR notes ILIKE :term", term: pattern)
    end
    @assets = @assets.where(asset_type: params[:kind]) if params[:kind].present?
  end

  def new
    @asset = current_user.manual_assets.new(asset_type: "property", currency: "USD", valued_on: Date.current)
  end

  def create
    @asset = current_user.manual_assets.new(asset_params)
    if @asset.save
      redirect_to manual_assets_path, notice: "Asset added to your net worth."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @asset.update(asset_params)
      redirect_to manual_assets_path, notice: "Asset valuation saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def find_asset
    @asset = current_user.manual_assets.find(params[:id])
  end

  def asset_params
    permitted = params.require(:manual_asset).permit(:name, :asset_type, :value, :valued_on, :notes)
    permitted[:currency] = params.require(:manual_asset)[:currency] if @asset.nil? || @asset.new_record?
    permitted
  end
end
