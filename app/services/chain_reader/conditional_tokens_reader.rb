module ChainReader
  # Gnosis CTF (Conditional Tokens Framework) reader. Polymarket's
  # ConditionalTokens is the canonical Gnosis deployment at
  # `0x4d97...6045` on Polygon, but this reader is protocol-agnostic — it
  # works against any Gnosis CTF deployment.
  #
  # Public surface:
  #
  #   read_state(chain:, ct_address:, condition_id:)
  #     → State(state: :unresolved|:resolved, outcome_slot_count:,
  #             payout_denominator:, payout_numerators:, block_number:)
  #
  #   position_ids(chain:, ct_address:, collateral:, condition_id:, index_sets:)
  #     → [Integer]  (one position ID per input index set, order preserved)
  #
  #   balances(chain:, ct_address:, owner:, position_ids:)
  #     → Balances(values: [Integer|nil], block_number:)
  #
  # Position-ID derivation defers to the on-chain `getCollectionId` +
  # `getPositionId` view functions rather than reimplementing Gnosis's
  # alt_bn128 hash-to-point math in Ruby. That's two eth_calls the first
  # time per (collateral, conditionId, indexSet), zero after — Solid Cache
  # holds the result for 30 days since position IDs never change once a
  # condition is prepared.
  class ConditionalTokensReader
    BYTES32_ZERO = ("\x00" * 32).b.freeze

    GET_OUTCOME_SLOT_COUNT_FN = {
      "name" => "getOutcomeSlotCount",
      "inputs" => [ { "type" => "bytes32" } ],
      "outputs" => [ { "type" => "uint256" } ]
    }.freeze

    PAYOUT_DENOMINATOR_FN = {
      "name" => "payoutDenominator",
      "inputs" => [ { "type" => "bytes32" } ],
      "outputs" => [ { "type" => "uint256" } ]
    }.freeze

    PAYOUT_NUMERATORS_FN = {
      "name" => "payoutNumerators",
      "inputs" => [ { "type" => "bytes32" }, { "type" => "uint256" } ],
      "outputs" => [ { "type" => "uint256" } ]
    }.freeze

    GET_COLLECTION_ID_FN = {
      "name" => "getCollectionId",
      "inputs" => [ { "type" => "bytes32" }, { "type" => "bytes32" }, { "type" => "uint256" } ],
      "outputs" => [ { "type" => "bytes32" } ]
    }.freeze

    GET_POSITION_ID_FN = {
      "name" => "getPositionId",
      "inputs" => [ { "type" => "address" }, { "type" => "bytes32" } ],
      "outputs" => [ { "type" => "uint256" } ]
    }.freeze

    BALANCE_OF_FN = {
      "name" => "balanceOf",
      "inputs" => [ { "type" => "address" }, { "type" => "uint256" } ],
      "outputs" => [ { "type" => "uint256" } ]
    }.freeze

    POSITION_ID_CACHE_TTL = 30.days

    State = Struct.new(:state, :outcome_slot_count, :payout_denominator,
                       :payout_numerators, :block_number, keyword_init: true) do
      def resolved?
        state == :resolved
      end
    end

    Balances = Struct.new(:values, :block_number, keyword_init: true)

    class << self
      # Reads the resolution state of a condition. Two batches in the resolved
      # case, one in the unresolved case (numerators read is skipped when
      # payout_denominator is zero).
      def read_state(chain:, ct_address:, condition_id:)
        cid = to_bytes32(condition_id)

        scalar_batch = Multicall3Client.call(chain: chain, calls: [
          Multicall3Client::Call.new(target: ct_address, function: GET_OUTCOME_SLOT_COUNT_FN, args: [ cid ]),
          Multicall3Client::Call.new(target: ct_address, function: PAYOUT_DENOMINATOR_FN, args: [ cid ])
        ])

        slot_result, denom_result = scalar_batch.results

        unless slot_result&.success && denom_result&.success
          return State.new(state: :unknown, block_number: scalar_batch.block_number)
        end

        outcome_slot_count = slot_result.values.first.to_i
        payout_denominator = denom_result.values.first.to_i

        if payout_denominator.zero?
          return State.new(
            state: :unresolved,
            outcome_slot_count: outcome_slot_count,
            payout_denominator: 0,
            payout_numerators: nil,
            block_number: scalar_batch.block_number
          )
        end

        numerator_batch = Multicall3Client.call(
          chain: chain,
          calls: (0...outcome_slot_count).map do |i|
            Multicall3Client::Call.new(
              target: ct_address,
              function: PAYOUT_NUMERATORS_FN,
              args: [ cid, i ]
            )
          end
        )
        numerators = numerator_batch.results.map { |r| r.success ? r.values.first.to_i : nil }

        State.new(
          state: :resolved,
          outcome_slot_count: outcome_slot_count,
          payout_denominator: payout_denominator,
          payout_numerators: numerators,
          block_number: [ scalar_batch.block_number, numerator_batch.block_number ].compact.min
        )
      end

      # Derives ERC-1155 position IDs for the given index sets. For Polymarket
      # binary markets, callers pass index_sets [1, 2] meaning [YES, NO]. For
      # neg-risk multi-outcome markets, [1, 2, 4, ..., 2^(n-1)].
      #
      # Cached per (chain, ct_address, collateral, condition_id, index_set) —
      # the derivation is deterministic and immutable.
      def position_ids(chain:, ct_address:, collateral:, condition_id:, index_sets:)
        cid_hex = normalize_hex(condition_id)
        cid_bytes = to_bytes32(condition_id)
        ct_lc = ct_address.downcase
        collateral_lc = collateral.downcase

        index_sets.map do |index_set|
          cache_key = "ct_position_id:v1:#{chain.slug}:#{ct_lc}:#{collateral_lc}:#{cid_hex}:#{index_set}"
          Rails.cache.fetch(cache_key, expires_in: POSITION_ID_CACHE_TTL) do
            collection_id = fetch_collection_id(chain, ct_address, cid_bytes, index_set.to_i)
            fetch_position_id(chain, ct_address, collateral_lc, collection_id)
          end
        end
      end

      def balances(chain:, ct_address:, owner:, position_ids:)
        return Balances.new(values: [], block_number: nil) if position_ids.empty?

        calls = position_ids.map do |pid|
          Multicall3Client::Call.new(
            target: ct_address,
            function: BALANCE_OF_FN,
            args: [ owner, pid.to_i ]
          )
        end
        batch = Multicall3Client.call(chain: chain, calls: calls)
        values = batch.results.map { |r| r.success ? r.values.first.to_i : nil }
        Balances.new(values: values, block_number: batch.block_number)
      end

      private

      # Accepts "0x<64 hex>" or a 32-byte binary string. Returns 32-byte binary
      # suitable for Eth::Abi.encode("bytes32", …).
      def to_bytes32(input)
        if input.is_a?(String) && input.encoding == Encoding::ASCII_8BIT && input.bytesize == 32
          return input
        end

        hex = input.to_s.sub(/\A0x/, "").downcase
        unless hex.match?(/\A[0-9a-f]{64}\z/)
          raise ArgumentError, "expected 0x-prefixed 32-byte hex, got: #{input.inspect}"
        end

        [ hex ].pack("H*").b
      end

      def normalize_hex(input)
        "0x" + input.to_s.sub(/\A0x/, "").downcase
      end

      def fetch_collection_id(chain, ct_address, cid_bytes, index_set)
        sel = Base.selector("getCollectionId(bytes32,bytes32,uint256)")
        encoded = Eth::Abi.encode(
          [ "bytes32", "bytes32", "uint256" ],
          [ BYTES32_ZERO, cid_bytes, index_set ]
        ).unpack1("H*")
        hex = Base.eth_call_hex(chain, to: ct_address, data: sel + encoded)
        Eth::Abi.decode([ "bytes32" ], Base.hex_to_bytes(hex)).first
      end

      def fetch_position_id(chain, ct_address, collateral, collection_id)
        sel = Base.selector("getPositionId(address,bytes32)")
        encoded = Eth::Abi.encode(
          [ "address", "bytes32" ],
          [ collateral, collection_id ]
        ).unpack1("H*")
        hex = Base.eth_call_hex(chain, to: ct_address, data: sel + encoded)
        Eth::Abi.decode([ "uint256" ], Base.hex_to_bytes(hex)).first.to_i
      end
    end
  end
end
