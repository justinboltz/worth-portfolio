class SessionsController < ApplicationController
  def new
  end

  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)

    if user&.authenticate(params[:password])
      destination = session.delete(:return_to)
      reset_session
      session[:user_id] = user.id
      session[:user_session_token] = user.session_token
      redirect_to destination.presence || root_path, allow_other_host: false
    else
      flash.now[:alert] = "Invalid email or password."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to sign_in_path
  end
end
