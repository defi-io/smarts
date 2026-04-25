class ContractsController < ApplicationController
  def show
    chain_slug, address = resolve_chain_and_address
    @chain = Chain.find_by!(slug: chain_slug)

    # Hex URL that has a slug → 301 to the canonical slug form. Format is
    # preserved so `/eth/0xa0b8….md` redirects to `/usdc-eth.md`, not the
    # default HTML view.
    if params[:address].present? && (slug = ContractSlugs.for(chain_slug, address))
      return redirect_to canonical_path(slug), status: :moved_permanently
    end

    @contract = Contract.find_by(chain: @chain, address: address)

    if @contract.nil? || @contract.abi.blank?
      info = EtherscanClient.new(@chain).fetch_contract_info(address)
      @contract = Contract.find_or_initialize_by(chain: @chain, address: address)
      @contract.update!(info)
    end

    @canonical_slug = ContractSlugs.for(chain_slug, address)
    @live_snapshot = load_live_values(@contract)
    @live_values = @live_snapshot
    @protocol_adapter = resolve_protocol_adapter(@contract)
    @classification = classify(@contract)

    enqueue_ai_enrichment_if_needed(@contract)
  rescue EtherscanClient::NotVerifiedError
    @address = address
    @inspection = inspect_address(@chain, address)
    respond_to do |format|
      format.html { render :not_verified, status: :not_found }
      format.md   { render plain: unverified_markdown(@chain, address, @inspection), status: :not_found, content_type: "text/markdown" }
    end
  rescue EtherscanClient::Error => e
    respond_to do |format|
      format.html do
        flash.now[:alert] = "Failed to fetch contract: #{e.message}"
        render :error, status: :service_unavailable
      end
      format.md { render plain: "# Error\n\nFailed to fetch contract at #{address} on #{@chain&.name || chain_slug}: #{e.message}\n", status: :service_unavailable, content_type: "text/markdown" }
    end
  end

  private

  # Returns [chain_slug, address] from either slug or chain/address params.
  # Raises ActionController::RoutingError for an unknown slug so the route
  # surfaces a clean 404 instead of NoMethodError down the line.
  def resolve_chain_and_address
    if params[:slug].present?
      lookup = ContractSlugs.resolve(params[:slug])
      raise ActionController::RoutingError, "unknown slug: #{params[:slug]}" unless lookup

      [ lookup[0], lookup[1].downcase ]
    else
      [ params[:chain], params[:address].to_s.downcase ]
    end
  end

  def load_live_values(contract)
    ChainReader::ViewCaller.call(contract)
  rescue => e
    Rails.logger.warn("[ContractsController] live values failed: #{e.class}: #{e.message}")
    ChainReader::ViewCaller::Snapshot.new(results: {}, block_number: nil, fetched_at: nil)
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

  def canonical_path(slug)
    params[:format] == "md" ? "/#{slug}.md" : "/#{slug}"
  end

  def unverified_markdown(chain, address, inspection)
    kind =
      if inspection&.respond_to?(:eoa?) && inspection.eoa?
        "externally owned account (EOA)"
      elsif inspection&.is_contract
        "unverified contract"
      else
        "unknown address"
      end

    <<~MD
      # Unverified: #{address} on #{chain.name}

      smarts.md only documents verified smart contracts. This address is an #{kind}.

      View raw on-chain state: <https://smarts.md/#{chain.slug}/#{address}>
    MD
  end
end
