# frozen_string_literal: true

class GetGovernanceTimelineTool < ApplicationTool
  tool_name "get_governance_timeline"
  description "Return the governance / admin event history for a contract, newest first. Surfaces only privileged events (role changes, pauses, proxy upgrades, blacklisting, minter config) — never per-user Transfer/Approval traffic. Each event includes a human-readable `summary` and a `category` (role_change, config, upgrade, lifecycle, risk_action). First call on a contract backfills ~90 days; subsequent calls are incremental. Pass `category` to filter. Accepts slug or chain+address."

  CATEGORIES = GovernanceEvent::CATEGORIES

  input_schema(
    properties: {
      slug:     { type: "string", description: "Curated slug like 'usdc-eth' or 'uni-eth'. Alternative to chain+address." },
      chain:    { type: "string", description: "Chain slug: eth, base, arbitrum, optimism, or polygon. Required unless `slug` is given." },
      address:  { type: "string", description: "0x-prefixed contract address. Required unless `slug` is given." },
      category: { type: "string", description: "Optional. Filter to one of: #{CATEGORIES.join(', ')}." },
      limit:    { type: "integer", description: "Max events to return. Default 100, no hard cap." }
    }
  )

  class << self
    def payload(chain: nil, address: nil, slug: nil, category: nil, limit: 100)
      resolved = resolve_contract(chain: chain, address: address, slug: slug)
      return resolved if resolved.is_a?(Hash)

      _chain_record, contract = resolved
      result = GovernanceEvents::TimelineFetcher.call(contract: contract)

      events = result.events
      events = events.select { |e| e.category == category } if category.present?
      events = events.first(limit.to_i) if limit.to_i.positive?

      base = {
        contract: result.contract,
        chain: result.chain,
        latest_block: result.latest_block,
        total_events: result.total_events,
        newly_fetched: result.newly_fetched,
        category_filter: category,
        events: events.map { |e| event_payload(e) }
      }
      base[:error] = result.error unless result.success?
      base
    end

    private

    def event_payload(event)
      {
        block_number: event.block_number,
        timestamp: event.block_timestamp&.iso8601,
        tx_hash: event.tx_hash,
        log_index: event.log_index,
        event: event.event_name,
        category: event.category,
        summary: event.summary,
        args: event.args
      }
    end
  end
end
