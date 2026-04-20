class ContractsController < ApplicationController
  def show
    @chain = Chain.find_by!(slug: params[:chain])
    address = params[:address].downcase

    @contract = Contract.find_by(chain: @chain, address: address)

    if @contract.nil? || @contract.abi.blank?
      info = EtherscanClient.new(@chain).fetch_contract_info(address)
      @contract = Contract.find_or_initialize_by(chain: @chain, address: address)
      @contract.update!(info)
    end
  rescue EtherscanClient::NotVerifiedError
    render :not_verified, status: :not_found
  rescue EtherscanClient::Error => e
    flash.now[:alert] = "Failed to fetch contract: #{e.message}"
    render :error, status: :service_unavailable
  end
end
