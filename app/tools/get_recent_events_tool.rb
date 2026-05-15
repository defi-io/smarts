# frozen_string_literal: true

class GetRecentEventsTool < ApplicationTool
  tool_name "get_recent_events"
  description "List the most recent events emitted by a contract, decoded against its ABI. Returns up to `limit` events (default 20, max 100), newest first. Pass `event_name` to filter to a single event signature (e.g. 'Swap', 'Transfer'). Unknown topics are returned with event='Unknown' and the raw topic0 + data — never errors out per-log. Accepts slug or chain+address."

  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100

  # Etherscan's logs endpoint silently *ignores* the `sort` parameter —
  # records always come back in ascending block order, regardless. Page 1
  # therefore contains the *earliest* events in the [fromBlock, toBlock]
  # range, never the most recent. Workaround: constrain the window tight
  # enough that the full page (1000 = Etherscan's max) covers everything,
  # then reverse client-side to surface newest-first.
  #
  # 5_000 blocks ≈ 17h on ETH (12s/block), ~3h on Base/OP/Polygon (2s),
  # ~21min on Arbitrum (0.25s). Picks up plenty for active contracts;
  # cold contracts with no recent activity may return fewer than `limit`
  # — that's an honest signal, not a bug.
  RECENT_BLOCK_WINDOW = 5_000

  # Etherscan's per-page maximum. We always fetch a full page so that, after
  # reversing client-side, we have the actual most-recent events to slice.
  ETHERSCAN_MAX_OFFSET = 1000

  input_schema(
    properties: {
      slug:       { type: "string",  description: "Curated slug like 'univ3-usdc-weth-eth' or 'usdc-eth'. Alternative to chain+address." },
      chain:      { type: "string",  description: "Chain slug: eth, base, arbitrum, optimism, or polygon. Required unless `slug` is given." },
      address:    { type: "string",  description: "0x-prefixed contract address. Required unless `slug` is given." },
      event_name: { type: "string",  description: "Optional. Filter to a single event by ABI name (e.g. 'Transfer'). Server-side filter via topic0." },
      limit:      { type: "integer", description: "Number of events to return, 1..#{MAX_LIMIT}. Default #{DEFAULT_LIMIT}." }
    }
  )

  class << self
    def payload(chain: nil, address: nil, slug: nil, event_name: nil, limit: DEFAULT_LIMIT)
      resolved = resolve_contract(chain: chain, address: address, slug: slug)
      return resolved if resolved.is_a?(Hash)

      _chain_record, contract = resolved
      capped_limit = limit.to_i.clamp(1, MAX_LIMIT)

      events_abi = contract.events
      target_event = nil

      if event_name.present?
        target_event = events_abi.find { |e| e["name"] == event_name }
        return { error: "event not in ABI: #{event_name}" } unless target_event
      end

      topic0 = target_event && ChainReader::EventDecoder.event_topic0(target_event)

      latest_block = ChainReader::Base.eth_block_number(contract.chain)
      from_block = [ latest_block - RECENT_BLOCK_WINDOW, 0 ].max

      raw_logs = EtherscanClient.new(contract.chain).get_logs(
        address:    contract.address,
        topic0:     topic0,
        from_block: from_block,
        to_block:   latest_block,
        offset:     ETHERSCAN_MAX_OFFSET
      )

      # Etherscan returns ascending; reverse for newest-first, then slice.
      decoded = raw_logs.reverse.first(capped_limit).map { |log| format_event(log, events_abi) }

      {
        contract: contract.address,
        chain: contract.chain.slug,
        event_filter: event_name,
        count: decoded.size,
        events: decoded
      }
    rescue EtherscanClient::Error => e
      { error: "Etherscan: #{e.message}" }
    end

    private

    def format_event(raw_log, events_abi)
      decoded = ChainReader::EventDecoder.call(events_abi: events_abi, log: raw_log)

      base = {
        block_number: hex_to_int(raw_log["blockNumber"]),
        tx_hash:      raw_log["transactionHash"],
        log_index:    hex_to_int(raw_log["logIndex"]),
        timestamp:    iso_timestamp(raw_log["timeStamp"])
      }

      if decoded
        base.merge(event: decoded.event_name, args: decoded.args)
      else
        base.merge(
          event: "Unknown",
          topic0: Array(raw_log["topics"]).first,
          raw_data: raw_log["data"]
        )
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
  end
end
