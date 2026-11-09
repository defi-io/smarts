# frozen_string_literal: true

module GovernanceEvents
  # Pulls historical governance events for a contract via per-event-type
  # topic0 filters, decodes them against the ABI, persists to the
  # governance_events table, and supports incremental re-scans by tracking
  # the contract's last scanned block.
  #
  # Sparse event semantics make this work where 24h-volume aggregation would
  # not: even high-activity governance events (USDC Blacklisted) are 1000x
  # rarer than Transfers, so full multi-year history typically completes in
  # a handful of Etherscan calls per event type.
  class TimelineFetcher
    # ~90 days on Ethereum (12s blocks). Long-lived contracts (USDC, etc.)
    # have plenty of governance activity inside this window for the first
    # render; the rest of history can be backfilled later.
    RECENT_BLOCK_WINDOW = 600_000

    # Etherscan's getLogs caps a single query at 10k results. Chunk the
    # block range so we never silently lose tail events.
    WINDOW_SIZE = 500_000
    PAGE_SIZE = 1000
    MAX_PAGES_PER_WINDOW = 10

    # Result#events carries only the newest N rows; total_events is a COUNT.
    # Loading every row (hundreds of thousands on busy contracts) every 30
    # minutes is what pushed the job worker past 1 GB RSS.
    EVENTS_LIMIT = 500

    Result = Struct.new(:contract, :chain, :total_events, :newly_fetched,
                       :latest_block, :events, :error, :refreshing,
                       keyword_init: true) do
      def success?
        error.blank?
      end

      def refreshing?
        refreshing == true
      end
    end

    def self.call(contract:)
      new(contract: contract).call
    end

    def self.recent_events(contract, category: nil, limit: EVENTS_LIMIT)
      scope = contract.governance_events.newest_first
      scope = scope.where(category: category) if category.present?
      scope.limit(limit).to_a
    end

    def initialize(contract:)
      @contract = contract
    end

    def call
      governance_abi = Classifier.filter(@contract.events)
      return empty_result if governance_abi.empty?

      latest_block = ChainReader::Base.eth_block_number(@contract.chain)
      from_block = determine_start_block(latest_block)

      newly = 0
      failures = []
      governance_abi.each do |event_abi|
        begin
          topic0 = ChainReader::EventDecoder.event_topic0(event_abi)
          newly += fetch_event_type(event_abi, topic0, from_block, latest_block)
        rescue ExplorerClient::Error, ChainReader::Base::RpcError => e
          failures << "#{event_abi['name']}: #{e.message}"
          Rails.logger.warn("[GovernanceEvents] #{event_abi['name']} failed: #{e.class}: #{e.message}")
        end
      end

      # Advance the cursor even on partial failure. Failed event types lose
      # their deep history but the next page view scans only [latest_block+1,
      # latest], a tiny window that won't trip the rate limiter on retry.
      @contract.update!(governance_last_scanned_block: latest_block)

      build_result(
        latest_block: latest_block,
        newly_fetched: newly,
        error: failures.any? ? "partial scan: #{failures.join('; ')}" : nil
      )
    rescue StandardError => e
      Rails.logger.error("[GovernanceEvents::TimelineFetcher] failed: #{e.class}: #{e.message}")
      error_result("#{e.class}: #{e.message}")
    end

    private

    def determine_start_block(latest_block)
      last = @contract.governance_last_scanned_block
      return last + 1 if last.present?

      [ latest_block - RECENT_BLOCK_WINDOW, 0 ].max
    end

    def fetch_event_type(event_abi, topic0, from_block, to_block)
      return 0 if from_block > to_block

      count = 0
      window_start = from_block
      while window_start <= to_block
        window_end = [ window_start + WINDOW_SIZE - 1, to_block ].min
        count += fetch_window(event_abi, topic0, window_start, window_end)
        window_start = window_end + 1
      end
      count
    end

    def fetch_window(event_abi, topic0, from, to)
      newly = 0
      page = 1
      loop do
        logs = fetch_logs(topic0: topic0, from_block: from, to_block: to, page: page)
        break if logs.empty?

        logs.each { |log| newly += 1 if persist(event_abi, log) }

        break if logs.length < PAGE_SIZE || page >= MAX_PAGES_PER_WINDOW
        page += 1
      end
      newly
    end

    # On eth mainnet: try Etherscan first (pagination + timestamps), fall back
    # to RPC on dynamic failure. Everywhere else the explorer can't serve logs
    # (free-tier Etherscan, or Blockscout), go straight to RPC (no pagination,
    # page>1 not meaningful).
    def fetch_logs(topic0:, from_block:, to_block:, page: 1)
      unless explorer.logs_supported?
        return [] if page > 1

        return ChainReader::Base.eth_get_logs(
          @contract.chain,
          address: @contract.address,
          topic0: topic0,
          from_block: from_block,
          to_block: to_block
        )
      end

      explorer.get_logs(
        address: @contract.address,
        topic0: topic0,
        from_block: from_block,
        to_block: to_block,
        page: page,
        offset: PAGE_SIZE,
        sort: "asc"
      )
    rescue ExplorerClient::Error => e
      # RPC doesn't support pagination; only use on first page to avoid dupes.
      raise if page > 1

      Rails.logger.info("[GovernanceEvents] Etherscan logs failed (#{e.message}), falling back to RPC")
      ChainReader::Base.eth_get_logs(
        @contract.chain,
        address: @contract.address,
        topic0: topic0,
        from_block: from_block,
        to_block: to_block
      )
    end

    def persist(event_abi, raw_log)
      decoded = ChainReader::EventDecoder.call(events_abi: [ event_abi ], log: raw_log)
      return false unless decoded

      args = decoded.args.respond_to?(:to_h) ? decoded.args.to_h : {}
      record = GovernanceEvent.new(
        contract: @contract,
        block_number: hex_to_int(raw_log["blockNumber"]),
        tx_hash: raw_log["transactionHash"],
        log_index: hex_to_int(raw_log["logIndex"]),
        event_name: decoded.event_name,
        category: Classifier.category_for(event_abi),
        args: args,
        summary: Classifier.summarize(decoded.event_name, args),
        block_timestamp: parse_timestamp(raw_log["timeStamp"])
      )
      record.save
      record.persisted?
    end

    def explorer
      @explorer ||= @contract.chain.explorer_client
    end

    def build_result(latest_block:, newly_fetched:, error: nil)
      Result.new(
        contract: @contract.address,
        chain: @contract.chain.slug,
        total_events: @contract.governance_events.count,
        newly_fetched: newly_fetched,
        latest_block: latest_block,
        events: self.class.recent_events(@contract),
        error: error
      )
    end

    def empty_result
      Result.new(
        contract: @contract.address,
        chain: @contract.chain.slug,
        total_events: 0,
        newly_fetched: 0,
        latest_block: nil,
        events: [],
        error: nil
      )
    end

    def error_result(message)
      Result.new(
        contract: @contract.address,
        chain: @contract.chain.slug,
        total_events: 0,
        newly_fetched: 0,
        latest_block: nil,
        events: self.class.recent_events(@contract),
        error: message
      )
    end

    def hex_to_int(hex)
      return nil if hex.nil?

      hex.to_s.sub(/\A0x/, "").to_i(16)
    end

    def parse_timestamp(hex)
      ts = hex_to_int(hex)
      ts && ts > 0 ? Time.at(ts).utc : nil
    end
  end
end
