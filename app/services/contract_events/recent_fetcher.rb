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
      raw_logs = EtherscanClient.new(@contract.chain).get_logs(
        address: @contract.address,
        topic0: topic0,
        from_block: from,
        to_block: latest,
        offset: ETHERSCAN_MAX_OFFSET
      )

      events = raw_logs.reverse.first(@limit).map { |log| build_event(log) }
      result(latest_block: latest, from_block: from, count: events.size, events: events)
    rescue EtherscanClient::Error => e
      error_result("Etherscan: #{e.message}")
    end

    private

    def events_abi
      @events_abi ||= @contract.events
    end

    def target_event
      @target_event ||= events_abi.find { |event| event["name"] == @event_name }
    end

    def topic0
      target_event && ChainReader::EventDecoder.event_topic0(target_event)
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
