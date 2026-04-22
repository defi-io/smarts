class MarketingController < ApplicationController
  def home
    if params[:q].present? && params[:q].match?(%r{\A[a-z]+/0x[0-9a-fA-F]{40}\z})
      redirect_to "/#{params[:q]}", status: :moved_permanently
    end
  end
end
