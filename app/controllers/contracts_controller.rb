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
        # Shell: activity / governance / full live state load via Turbo Frame
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
          @governance = load_governance_timeline(@contract)
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
  end

  def activity
    load_island_contract
    return render_docs_only_island if @chain.docs_only?

    @activity = load_recent_events(@contract)
    @classification = classify(@contract)
    @live_values = load_live_values(@contract)
    expires_in 30.seconds, public: true, stale_while_revalidate: 60.seconds
    render layout: false
  end

  def governance
    load_island_contract
    return render_docs_only_island if @chain.docs_only?

    @governance = load_governance_timeline(@contract)
    expires_in 1.hour, public: true
    render layout: false
  end

  def source
    load_island_contract
    expires_in 1.day, public: true
    render layout: false
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

  def load_governance_timeline(contract)
    # Synchronously serve whatever's already persisted; Etherscan calls happen
    # in the background via GovernanceTimelineRefreshJob (broadcasts a Turbo
    # morph refresh when done). Keeps the show action sub-second even on cold
    # contracts where a full backfill would otherwise take 5-10s.
    cached_events = contract.governance_events.newest_first.to_a
    refreshing = false

    unless GovernanceTimelineRefreshJob.fresh?(contract)
      GovernanceTimelineRefreshJob.perform_later(contract.id)
      refreshing = true
    end

    GovernanceEvents::TimelineFetcher::Result.new(
      contract: contract.address,
      chain: contract.chain.slug,
      total_events: cached_events.length,
      newly_fetched: 0,
      latest_block: contract.governance_last_scanned_block,
      events: cached_events,
      error: nil,
      refreshing: refreshing
    )
  rescue => e
    Rails.logger.warn("[ContractsController] governance fetch failed: #{e.class}: #{e.message}")
    GovernanceEvents::TimelineFetcher::Result.new(
      contract: contract.address,
      chain: contract.chain.slug,
      total_events: 0,
      newly_fetched: 0,
      latest_block: nil,
      events: contract.governance_events.newest_first.to_a,
      error: e.message,
      refreshing: false
    )
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
      recent_governance: { count: contract.governance_events.count },
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

  # Renders a friendly notice in a Turbo Frame for docs_only chains. Used by
  # live/activity/governance island actions so they fail fast instead of
  # spinning up RPC calls that aren't configured for the chain.
  def render_docs_only_island
    frame_id =
      case action_name
      when "live"       then "contract_live"
      when "activity"   then "contract_activity"
      when "governance" then "contract_governance"
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
