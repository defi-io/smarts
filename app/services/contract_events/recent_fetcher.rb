# frozen_string_literal: true

module ContractEvents
  # Fetches recent logs for a verified contract and decodes them against the
  # contract ABI. Shared by the HTML/Markdown contract pages and the MCP
  # get_recent_events tool so the "recent activity" semantics stay identical.
  class RecentFetcher
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100

    # Etherscan's logs endpoint returns page 1 in ascending block order even
    # when `sort=desc` is supplied. Pull a bounded full page, reverse locally,
    # then slice to the requested limit.
    RECENT_BLOCK_WINDOW = 5_000
    ETHERSCAN_MAX_OFFSET = 1000

    Result = Struct.new(:contract, :chain, :event_filter, :latest_block,
                        :from_block, :count, :events, :error, keyword_init: true) do
      def success?
        error.blank?
      end
    end

    Event = Struct.new(:event, :args, :block_number, :tx_hash, :log_index,
                       :timestamp, :topic0, :raw_data, keyword_init: true) do
      def unknown?
        event == "Unknown"
      end

      def to_h
        base = {
          event: event,
          block_number: block_number,
          tx_hash: tx_hash,
          log_index: log_index,
          timestamp: timestamp
        }

        if unknown?
          base.merge(topic0: topic0, raw_data: raw_data)
        else
          base.merge(args: args)
        end
      end
    end

    def self.call(contract:, event_name: nil, limit: DEFAULT_LIMIT)
      new(contract: contract, event_name: event_name, limit: limit).call
    end

    def initialize(contract:, event_name: nil, limit: DEFAULT_LIMIT)
      @contract = contract
      @event_name = event_name.presence
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
    end

    def call
      return error_result("event not in ABI: #{@event_name}") if @event_name && target_event.nil?

      latest = ChainReader::Base.eth_block_number(@contract.chain)
      from = [ latest - RECENT_BLOCK_WINDOW, 0 ].max
      raw_logs = fetch_logs(from, latest)
      from = @effective_from_block || from

      events = raw_logs.reverse.first(@limit).map { |log| build_event(log) }
      result(latest_block: latest, from_block: from, count: events.size, events: events)
    rescue ExplorerClient::Error, ChainReader::Base::RpcError => e
      error_result("Recent activity on #{@contract.chain.name} failed: #{e.message}")
    end

    private

    def explorer
      @explorer ||= @contract.chain.explorer_client
    end

    # On eth mainnet: try Etherscan first (richer response with timestamps),
    # fall back to RPC on dynamic failure. Everywhere else the explorer can't
    # serve logs (free-tier Etherscan, or Blockscout), go straight to RPC.
    def fetch_logs(from, latest)
      return rpc_get_logs_with_adaptive_window(from, latest) unless explorer.logs_supported?

      explorer.get_logs(
        address: @contract.address,
        topic0: topic0,
        from_block: from,
        to_block: latest,
        offset: ETHERSCAN_MAX_OFFSET
      )
    rescue ExplorerClient::Error => etherscan_error
      Rails.logger.info("[RecentFetcher] Etherscan logs failed (#{etherscan_error.message}), falling back to RPC")
      begin
        rpc_get_logs_with_adaptive_window(from, latest)
      rescue ChainReader::Base::RpcError => rpc_error
        raise ChainReader::Base::RpcError,
          "Etherscan logs failed on #{@contract.chain.name}: #{etherscan_error.message}; RPC fallback failed: #{rpc_error.message}"
      end
    end

    def rpc_get_logs_with_adaptive_window(from, latest)
      current_from = from
      loop do
        @effective_from_block = current_from
        return ChainReader::Base.eth_get_logs(
          @contract.chain,
          address: @contract.address,
          topic0: topic0,
          from_block: current_from,
          to_block: latest
        )
      rescue ChainReader::Base::RpcError => e
        raise unless shrinkable_rpc_error?(e) && current_from < latest

        current_from = latest - ((latest - current_from) / 2)
      end
    end

    def events_abi
      @events_abi ||= @contract.events
    end

    def target_event
      @target_event ||= events_abi.find { |event| event["name"] == @event_name }
    end

    def topic0
      target_event && ChainReader::EventDecoder.event_topic0(target_event)
    end

    # Node-specific ways of saying "that range matched too much" — all mean the
    # same thing: retry over a narrower window. Robinhood Chain's public RPC
    # phrases it "logs matched by query exceeds limit of 10000", which matters
    # there more than elsewhere: 100ms blocks put ~34k WETH Transfers inside
    # the default 5,000-block window.
    def shrinkable_rpc_error?(error)
      error.message.match?(/exceeds max results|exceeds limit|too many results|response size|query timeout|limit exceeded/i)
    end

    def build_event(raw_log)
      decoded = ChainReader::EventDecoder.call(events_abi: events_abi, log: raw_log)
      base = {
        block_number: hex_to_int(raw_log["blockNumber"]),
        tx_hash: raw_log["transactionHash"],
        log_index: hex_to_int(raw_log["logIndex"]),
        timestamp: iso_timestamp(raw_log["timeStamp"])
      }

      if decoded
        Event.new(**base.merge(event: decoded.event_name, args: decoded.args))
      else
        Event.new(**base.merge(
          event: "Unknown",
          topic0: Array(raw_log["topics"]).first,
          raw_data: raw_log["data"]
        ))
      end
    end

    def hex_to_int(hex)
      return nil if hex.nil?

      hex.to_s.sub(/\A0x/, "").to_i(16)
    end

    def iso_timestamp(hex)
      ts = hex_to_int(hex)
      ts && ts > 0 ? Time.at(ts).utc.iso8601 : nil
    end

    def result(latest_block: nil, from_block: nil, count: 0, events: [], error: nil)
      Result.new(
        contract: @contract.address,
        chain: @contract.chain.slug,
        event_filter: @event_name,
        latest_block: latest_block,
        from_block: from_block,
        count: count,
        events: events,
        error: error
      )
    end

    def error_result(message)
      result(error: message)
    end
  end
end
