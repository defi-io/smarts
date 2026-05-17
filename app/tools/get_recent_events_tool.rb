# frozen_string_literal: true

class GetRecentEventsTool < ApplicationTool
  tool_name "get_recent_events"
  description "List the most recent events emitted by a contract, decoded against its ABI. Returns up to `limit` events (default 20, max 100), newest first. Pass `event_name` to filter to a single event signature (e.g. 'Swap', 'Transfer'). Unknown topics are returned with event='Unknown' and the raw topic0 + data — never errors out per-log. Accepts slug or chain+address."

  DEFAULT_LIMIT = ContractEvents::RecentFetcher::DEFAULT_LIMIT
  MAX_LIMIT = ContractEvents::RecentFetcher::MAX_LIMIT
  RECENT_BLOCK_WINDOW = ContractEvents::RecentFetcher::RECENT_BLOCK_WINDOW
  ETHERSCAN_MAX_OFFSET = ContractEvents::RecentFetcher::ETHERSCAN_MAX_OFFSET

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
      result = ContractEvents::RecentFetcher.call(
        contract: contract,
        event_name: event_name,
        limit: limit
      )

      return { error: result.error } unless result.success?

      {
        contract: result.contract,
        chain: result.chain,
        event_filter: result.event_filter,
        count: result.count,
        events: result.events.map(&:to_h)
      }
    end
  end
end
