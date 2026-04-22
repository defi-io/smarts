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

    @live_values = load_live_values(@contract)
    @protocol_adapter = resolve_protocol_adapter(@contract)
    @classification = classify(@contract)

    enqueue_ai_enrichment_if_needed(@contract)
  rescue EtherscanClient::NotVerifiedError
    @address = address
    @inspection = inspect_address(@chain, address)
    render :not_verified, status: :not_found
  rescue EtherscanClient::Error => e
    flash.now[:alert] = "Failed to fetch contract: #{e.message}"
    render :error, status: :service_unavailable
  end

  private

  def load_live_values(contract)
    ChainReader::ViewCaller.call(contract)
  rescue => e
    Rails.logger.warn("[ContractsController] live values failed: #{e.class}: #{e.message}")
    {}
  end

  def resolve_protocol_adapter(contract)
    ProtocolAdapters::Base.resolve(contract)
  rescue => e
    Rails.logger.warn("[ContractsController] adapter resolve failed: #{e.class}: #{e.message}")
    nil
  end

  def classify(contract)
    ContractDocument::Classifier.call(contract)
  rescue => e
    Rails.logger.warn("[ContractsController] classify failed: #{e.class}: #{e.message}")
    nil
  end

  def inspect_address(chain, address)
    ChainReader::AddressInspector.call(chain: chain, address: address)
  rescue => e
    Rails.logger.warn("[ContractsController] address inspect failed: #{e.class}: #{e.message}")
    nil
  end

  def enqueue_ai_enrichment_if_needed(contract)
    return if contract.abi.blank? || contract.ai_natspec.present?
    return if contract.all_functions_have_natspec?

    EnrichContractAiJob.perform_later(contract)
  rescue => e
    Rails.logger.warn("[ContractsController] AI enqueue failed: #{e.class}: #{e.message}")
  end
end
