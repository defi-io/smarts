class ContractsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_contract_locale

  def show
    chain_slug, address = resolve_chain_and_address
    @chain = Chain.find_by!(slug: chain_slug)

    # Hex URL that has a slug → 301 to the canonical slug form. Format is
    # preserved so `/eth/0xa0b8….md` redirects to `/usdc-eth.md`, not the
    # default HTML view.
    if params[:address].present? && (slug = ContractSlugResolver.for(chain_slug, address))
      return redirect_to canonical_path(
        slug,
        chain_slug: chain_slug,
        address: address,
        locale: params[:locale].presence
      ), status: :moved_permanently
    end

    find_or_fetch_contract(address)
    @canonical_slug = canonical_slug_for_request(chain_slug, address)
    @classification = classify(@contract)
    @protocol_adapter = resolve_protocol_adapter(@contract) if @chain.full?
    @admin_risk = load_admin_risk_profile(@contract) if @chain.full?

    respond_to do |format|
      format.html do
        # Shell: activity / full live state load via Turbo Frame
        # islands. ViewCaller is still called here because the header needs
        # ERC-20 name/symbol via contract_display_name's live_value fallback —
        # without it brand names regress to the Solidity class ("FiatTokenV2_2").
        # Values are cached 60s in Solid Cache, so origin hits (rare under the
        # 1d shell CDN cache) usually skip the Multicall3.
        @live_snapshot = @chain.full? ? load_live_values(@contract) : empty_live_snapshot
        @live_values = @live_snapshot
        enqueue_ai_enrichment_if_needed(@contract)
        expires_in 1.day, public: true
        fresh_when etag: [ @contract.id, @contract.updated_at, @classification&.id ], public: true
      end
      format.md do
        # Markdown distillation needs full data inline.
        if @chain.full?
          @live_snapshot = load_live_values(@contract)
          @live_values = @live_snapshot
          @activity = load_recent_events(@contract)
        else
          @live_snapshot = empty_live_snapshot
          @live_values = @live_snapshot
        end
      end
    end
  rescue ExplorerClient::NotVerifiedError
    @address = address
    @inspection = inspect_address(@chain, address)
    respond_to do |format|
      format.html { render :not_verified, status: :not_found }
      format.md   { render plain: unverified_markdown(@chain, address, @inspection), status: :not_found, content_type: "text/markdown" }
    end
  rescue ExplorerClient::Error => e
    respond_to do |format|
      format.html do
        flash.now[:alert] = "Failed to fetch contract: #{e.message}"
        render :error, status: :service_unavailable
      end
      format.md { render plain: "# Error\n\nFailed to fetch contract at #{address} on #{@chain&.name || chain_slug}: #{e.message}\n", status: :service_unavailable, content_type: "text/markdown" }
    end
  end

  # ── Turbo Frame islands ──────────────────────────────────────────────

  def live
    load_island_contract
    return render_docs_only_island if @chain.docs_only?

    @protocol_adapter = resolve_protocol_adapter(@contract)
    @live_snapshot = load_live_values(@contract)
    @live_values = @live_snapshot
    @classification = classify(@contract)
    expires_in 30.seconds, public: true, stale_while_revalidate: 60.seconds
    render layout: false
  rescue ExplorerClient::NotVerifiedError
    render_unverified_island
  end

  def activity
    load_island_contract
    return render_docs_only_island if @chain.docs_only?

    @activity = load_recent_events(@contract)
    @classification = classify(@contract)
    @live_values = load_live_values(@contract)
    expires_in 30.seconds, public: true, stale_while_revalidate: 60.seconds
    render layout: false
  rescue ExplorerClient::NotVerifiedError
    render_unverified_island
  end

  def source
    load_island_contract
    expires_in 1.day, public: true
    render layout: false
  rescue ExplorerClient::NotVerifiedError
    render_unverified_island
  end

  private

  def load_island_contract
    chain_slug, address = resolve_chain_and_address
    @chain = Chain.find_by!(slug: chain_slug)
    @canonical_slug = canonical_slug_for_request(chain_slug, address)
    find_or_fetch_contract(address)
  end

  def find_or_fetch_contract(address)
    @contract = Contract.find_by(chain: @chain, address: address)
    if @contract.nil? || @contract.abi.blank?
      info = @chain.explorer_client.fetch_contract_info(address)
      @contract = Contract.find_or_initialize_by(chain: @chain, address: address)
      @contract.update!(info)
    end
  end

  # Returns [chain_slug, address] from either slug or chain/address params.
  # Raises ActionController::RoutingError for an unknown slug so the route
  # surfaces a clean 404 instead of NoMethodError down the line.
  def resolve_chain_and_address
    if params[:slug].present?
      lookup = ContractSlugResolver.resolve(params[:slug])
      raise ActionController::RoutingError, "unknown slug: #{params[:slug]}" unless lookup

      [ lookup[0], lookup[1].downcase ]
    else
      [ params[:chain], params[:address].to_s.downcase ]
    end
  end

  def canonical_slug_for_request(chain_slug, address)
    if params[:slug].present?
      ContractSlugResolver.canonical_for_slug(params[:slug])
    else
      ContractSlugResolver.for(chain_slug, address)
    end
  end

  def load_live_values(contract)
    ChainReader::ViewCaller.call(contract)
  rescue => e
    Rails.logger.warn("[ContractsController] live values failed: #{e.class}: #{e.message}")
    empty_live_snapshot
  end

  def empty_live_snapshot
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

  def load_recent_events(contract)
    ContractEvents::RecentFetcher.call(
      contract: contract,
      event_name: recent_event_filter(contract),
      limit: ContractEvents::RecentFetcher::DEFAULT_LIMIT
    )
  rescue => e
    Rails.logger.warn("[ContractsController] recent events failed: #{e.class}: #{e.message}")
    ContractEvents::RecentFetcher::Result.new(
      contract: contract.address,
      chain: contract.chain.slug,
      event_filter: recent_event_filter(contract),
      count: 0,
      events: [],
      error: e.message
    )
  end

  def recent_event_filter(contract)
    return nil if params[:event_name] == "all"
    return params[:event_name].presence if params[:event_name].present?

    return "Transfer" if contract.events.any? { |event| event["name"] == "Transfer" }

    nil
  end

  def load_admin_risk_profile(contract)
    AdminRisk::Profiler.call(contract: contract)
  rescue => e
    Rails.logger.warn("[ContractsController] admin risk profile failed: #{e.class}: #{e.message}")
    AdminRisk::Profiler::Result.new(
      contract: contract.address,
      chain: contract.chain.slug,
      summary: "Could not build admin risk profile.",
      risk_flags: [],
      controls: [],
      evidence: [],
      warnings: [],
      block_number: nil,
      fetched_at: nil,
      error: e.message
    )
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

  def canonical_path(slug, chain_slug:, address:, locale: nil)
    helpers.localized_contract_path(
      locale: locale || I18n.locale,
      slug: slug,
      chain_slug: chain_slug,
      address: address,
      format: params[:format]
    )
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

  # Island counterpart of show's not_verified page: the explorer no longer
  # returns verified source, so answer 404 inside the frame instead of a 500.
  def render_unverified_island
    render plain: <<~HTML, content_type: "text/html", status: :not_found
      <turbo-frame id="contract_#{action_name}">
        <div class="alert alert-warning">
          #{ERB::Util.h(t('contracts.not_verified.generic_heading'))}
        </div>
      </turbo-frame>
    HTML
  end

  # Renders a friendly notice in a Turbo Frame for docs_only chains. Used by
  # live/activity island actions so they fail fast instead of
  # spinning up RPC calls that aren't configured for the chain.
  def render_docs_only_island
    frame_id =
      case action_name
      when "live"       then "contract_live"
      when "activity"   then "contract_activity"
      end
    render plain: <<~HTML, content_type: "text/html"
      <turbo-frame id="#{frame_id}">
        <div class="alert alert-info">
          #{ERB::Util.h(t('contracts.show.docs_only_notice', chain: @chain.name))}
        </div>
      </turbo-frame>
    HTML
  end

  def set_contract_locale
    locale =
      if request.path_parameters[:locale].present?
        LOCALE_MAP[request.path_parameters[:locale]] || I18n.default_locale.to_s
      else
        I18n.default_locale.to_s
      end

    I18n.locale = locale

    return unless request.path_parameters[:locale].present?

    cookies[:locale] = {
      value: request.path_parameters[:locale],
      path: "/",
      expires: 1.year.from_now,
      same_site: :lax
    }
  end
end
