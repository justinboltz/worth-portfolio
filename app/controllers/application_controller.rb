class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :set_current_user
  before_action :load_account_sidebar

  helper_method :current_user, :signed_in?

  private

  def load_account_sidebar
    @sidebar_accounts = current_user ? current_user.accounts.tracked.order(:account_type, :name) : []
    @sidebar_assets = current_user ? current_user.manual_assets.order(:name) : []
  end

  def set_current_user
    Current.user = current_user
  end

  def current_user
    return @current_user if defined?(@current_user)

    user = User.find_by(id: session[:user_id])

    if user.present? && session[:user_session_token].present? && session[:user_session_token] == user.session_token
      @current_user = user
      return @current_user
    end

    reset_session if session[:user_id].present?
    @current_user = nil
  end

  def signed_in?
    current_user.present?
  end

  def require_authentication
    return if signed_in?

    session[:return_to] = request.fullpath if request.get? && !request.format.json?
    redirect_to sign_in_path, alert: "Please sign in."
  end
end
