# frozen_string_literal: true

class InspectAddressTool < ApplicationTool
  tool_name "inspect_address"
  description "Inspect any EVM address: classifies it as an EOA / unverified contract / EIP-7702 delegated wallet, returns native-token balance, outgoing tx count (nonce), and reverse-ENS name (Ethereum only). Works for unindexed addresses — useful before deciding whether to call get_contract_info or get_erc20_info."

  input_schema(
    properties: {
      chain:   { type: "string", description: "Chain slug. Tier 1 (live data) only: eth, base, arbitrum, optimism, bnb, polygon, robinhood, arc. Tier 2 (docs-only) chains return an error." },
      address: { type: "string", description: "Any 0x-prefixed EVM address (contract or EOA)." }
    },
    required: [ "chain", "address" ]
  )

  class << self
    def payload(chain:, address:)
      chain_record = Chain.find_by(slug: chain)
      return { error: "unknown chain: #{chain}" } unless chain_record

      tier_error = check_full_tier(chain_record)
      return tier_error if tier_error

      result = ChainReader::AddressInspector.call(chain: chain_record, address: address)

      {
        chain: chain,
        address: address.downcase,
        is_contract: result.is_contract,
        kind: classify_kind(result.is_contract),
        balance: {
          wei: result.balance_wei,
          native: result.balance_eth,
          symbol: chain_record.native_symbol
        },
        tx_count_sent: result.tx_count,
        ens_name: result.ens_name,
        fetched_at: result.fetched_at&.utc&.iso8601
      }
    end

    private

    def classify_kind(is_contract)
      case is_contract
      when true  then "contract"
      when false then "eoa"
      else nil # RPC failed entirely; caller should treat as unknown
      end
    end
  end
end
