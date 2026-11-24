class PasswordsController < ApplicationController
  before_action :require_authentication

  def edit
    @user = current_user
  end

  def update
    @user = current_user

    unless @user.authenticate(password_params[:current_password])
      @user.errors.add(:current_password, "is incorrect")
      return render :edit, status: :unprocessable_entity
    end

    if @user.update(password_params.to_h.except("current_password"))
      reset_session
      session[:user_id] = @user.id
      session[:user_session_token] = @user.session_token
      redirect_to root_path, notice: "Password updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def password_params
    params.require(:user).permit(:current_password, :password, :password_confirmation)
  end
end
