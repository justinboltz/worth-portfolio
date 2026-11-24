module Api
  module V1
    class BaseController < ApplicationController
      private

      def require_authentication
        return if signed_in?

        render json: { error: "unauthorized" }, status: :unauthorized
      end
    end
  end
end
