require "test_helper"

class ChainReader::ConditionalTokensReaderTest < ActiveSupport::TestCase
  CT_ADDRESS = "0x4d97dcd97ec945f40cf65f87097ace5ea0476045".freeze
  COLLATERAL = "0x2791bca1f2de4661ed88a30c99a7a9449aa84174".freeze # USDC.e
  CONDITION_ID = "0x" + ("ab" * 32) # arbitrary but well-formed 32-byte hex
  OWNER = "0x000000000000000000000000000000000000beef".freeze

  setup do
    @polygon = chains(:polygon)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  def ok(*values)
    ChainReader::Multicall3Client::Result.new(success: true, values: values)
  end

  def reverted
    ChainReader::Multicall3Client::Result.new(success: false, error: "execution reverted")
  end

  # ------------------------------------------------------------------
  # read_state
  # ------------------------------------------------------------------

  test "read_state returns :unresolved when payoutDenominator is zero, and skips the numerators batch" do
    # The reader should issue exactly one Multicall3 batch in the unresolved
    # case — the numerators read is wasted RPC when nothing is settled yet.
    calls_seen = 0
    stub = lambda do |chain:, calls:|
      calls_seen += 1
      assert_equal 2, calls.size, "unresolved path should issue scalars batch only"
      [ ok(2), ok(0) ] # outcome_slot_count=2, payout_denominator=0
    end

    state = nil
    stub_class_method(ChainReader::Multicall3Client, :call, stub) do
      state = ChainReader::ConditionalTokensReader.read_state(
        chain: @polygon, ct_address: CT_ADDRESS, condition_id: CONDITION_ID
      )
    end

    assert_equal 1, calls_seen
    assert_equal :unresolved, state.state
    assert_equal 2, state.outcome_slot_count
    assert_equal 0, state.payout_denominator
    assert_nil state.payout_numerators
  end

  test "read_state returns :resolved with payouts for a settled binary YES market" do
    batches = 0
    stub = lambda do |chain:, calls:|
      batches += 1
      if batches == 1
        assert_equal 2, calls.size
        [ ok(2), ok(1) ] # 2 outcomes, denominator=1 (settled)
      else
        assert_equal 2, calls.size # one numerator call per outcome
        [ ok(1), ok(0) ] # YES paid out, NO did not
      end
    end

    state = nil
    stub_class_method(ChainReader::Multicall3Client, :call, stub) do
      state = ChainReader::ConditionalTokensReader.read_state(
        chain: @polygon, ct_address: CT_ADDRESS, condition_id: CONDITION_ID
      )
    end

    assert_equal 2, batches
    assert_predicate state, :resolved?
    assert_equal 1, state.payout_denominator
    assert_equal [ 1, 0 ], state.payout_numerators
    assert_equal 2, state.outcome_slot_count
  end

  test "read_state issues n numerator calls for neg-risk markets with n outcomes" do
    batches = 0
    stub = lambda do |chain:, calls:|
      batches += 1
      if batches == 1
        [ ok(5), ok(1) ] # 5-outcome neg-risk market, denominator=1
      else
        assert_equal 5, calls.size
        [ ok(0), ok(1), ok(0), ok(0), ok(0) ] # outcome index 1 paid out
      end
    end

    state = nil
    stub_class_method(ChainReader::Multicall3Client, :call, stub) do
      state = ChainReader::ConditionalTokensReader.read_state(
        chain: @polygon, ct_address: CT_ADDRESS, condition_id: CONDITION_ID
      )
    end

    assert_equal [ 0, 1, 0, 0, 0 ], state.payout_numerators
    assert_equal 5, state.outcome_slot_count
  end

  test "read_state returns :unknown when scalar batch reverts (e.g. condition not prepared)" do
    stub = lambda do |chain:, calls:|
      [ reverted, reverted ]
    end

    state = nil
    stub_class_method(ChainReader::Multicall3Client, :call, stub) do
      state = ChainReader::ConditionalTokensReader.read_state(
        chain: @polygon, ct_address: CT_ADDRESS, condition_id: CONDITION_ID
      )
    end

    assert_equal :unknown, state.state
  end

  # ------------------------------------------------------------------
  # position_ids
  # ------------------------------------------------------------------

  test "position_ids derives via on-chain getCollectionId + getPositionId, caches the result" do
    # Encode the expected return values for two view calls:
    #   getCollectionId(0, conditionId, 1) → arbitrary collection hash
    #   getPositionId(collateral, collectionHash) → 12345
    collection_id_bytes = "\xCC".b * 32
    collection_id_hex = "0x" + Eth::Abi.encode([ "bytes32" ], [ collection_id_bytes ]).unpack1("H*")
    position_id_hex = "0x" + Eth::Abi.encode([ "uint256" ], [ 12345 ]).unpack1("H*")

    rpc_calls = []
    stub = lambda do |chain, to:, data:|
      rpc_calls << [ to.downcase, data[0, 10] ] # log destination + selector
      sel = data[0, 10]
      if sel == ChainReader::Base.selector("getCollectionId(bytes32,bytes32,uint256)")
        collection_id_hex
      elsif sel == ChainReader::Base.selector("getPositionId(address,bytes32)")
        position_id_hex
      else
        raise "unexpected selector: #{sel}"
      end
    end

    ids = nil
    stub_class_method(ChainReader::Base, :eth_call_hex, stub) do
      ids = ChainReader::ConditionalTokensReader.position_ids(
        chain: @polygon, ct_address: CT_ADDRESS, collateral: COLLATERAL,
        condition_id: CONDITION_ID, index_sets: [ 1 ]
      )
    end

    assert_equal [ 12345 ], ids
    assert_equal 2, rpc_calls.size

    # Repeat call must be a no-op — cache hit
    rpc_calls.clear
    stub_class_method(ChainReader::Base, :eth_call_hex, ->(*) { raise "must not be called" }) do
      cached = ChainReader::ConditionalTokensReader.position_ids(
        chain: @polygon, ct_address: CT_ADDRESS, collateral: COLLATERAL,
        condition_id: CONDITION_ID, index_sets: [ 1 ]
      )
      assert_equal [ 12345 ], cached
    end
  end

  test "position_ids preserves order of input index_sets" do
    # YES = indexSet 1, NO = indexSet 2. Polymarket UI convention.
    yes_pid = 111_111
    no_pid  = 222_222
    bytes_for_idx = { 1 => "\xAA".b * 32, 2 => "\xBB".b * 32 }
    pid_for_collection = {
      bytes_for_idx[1] => yes_pid,
      bytes_for_idx[2] => no_pid
    }

    stub = lambda do |chain, to:, data:|
      sel = data[0, 10]
      if sel == ChainReader::Base.selector("getCollectionId(bytes32,bytes32,uint256)")
        # The index_set is the last uint256 of the call data
        index_set = Eth::Abi.decode(
          [ "bytes32", "bytes32", "uint256" ],
          ChainReader::Base.hex_to_bytes(data[10..])
        )[2]
        collection_bytes = bytes_for_idx.fetch(index_set)
        "0x" + Eth::Abi.encode([ "bytes32" ], [ collection_bytes ]).unpack1("H*")
      elsif sel == ChainReader::Base.selector("getPositionId(address,bytes32)")
        collection_bytes = Eth::Abi.decode(
          [ "address", "bytes32" ],
          ChainReader::Base.hex_to_bytes(data[10..])
        )[1]
        "0x" + Eth::Abi.encode([ "uint256" ], [ pid_for_collection.fetch(collection_bytes) ]).unpack1("H*")
      end
    end

    ids = nil
    stub_class_method(ChainReader::Base, :eth_call_hex, stub) do
      ids = ChainReader::ConditionalTokensReader.position_ids(
        chain: @polygon, ct_address: CT_ADDRESS, collateral: COLLATERAL,
        condition_id: CONDITION_ID, index_sets: [ 1, 2 ]
      )
    end

    assert_equal [ yes_pid, no_pid ], ids
  end

  test "position_ids rejects malformed condition_id" do
    assert_raises(ArgumentError) do
      ChainReader::ConditionalTokensReader.position_ids(
        chain: @polygon, ct_address: CT_ADDRESS, collateral: COLLATERAL,
        condition_id: "0xabc", index_sets: [ 1 ]
      )
    end
  end

  # ------------------------------------------------------------------
  # balances
  # ------------------------------------------------------------------

  test "balances issues one Multicall3 batch for n position IDs, preserves order" do
    seen_args = nil
    stub = lambda do |chain:, calls:|
      seen_args = calls.map(&:args)
      [ ok(1_000_000), ok(2_500_000) ]
    end

    result = nil
    stub_class_method(ChainReader::Multicall3Client, :call, stub) do
      result = ChainReader::ConditionalTokensReader.balances(
        chain: @polygon, ct_address: CT_ADDRESS, owner: OWNER,
        position_ids: [ 111, 222 ]
      )
    end

    assert_equal [ 1_000_000, 2_500_000 ], result.values
    assert_equal [ [ OWNER, 111 ], [ OWNER, 222 ] ], seen_args
    assert_equal 19_000_000, result.block_number # default from stub_class_method wrap
  end

  test "balances tolerates a reverted balanceOf by reporting nil for that slot" do
    stub = lambda do |chain:, calls:|
      [ ok(5_000_000), reverted ]
    end

    result = nil
    stub_class_method(ChainReader::Multicall3Client, :call, stub) do
      result = ChainReader::ConditionalTokensReader.balances(
        chain: @polygon, ct_address: CT_ADDRESS, owner: OWNER,
        position_ids: [ 111, 222 ]
      )
    end

    assert_equal [ 5_000_000, nil ], result.values
  end

  test "balances skips the RPC when position_ids is empty" do
    stub_class_method(ChainReader::Multicall3Client, :call, ->(*) { raise "must not be called" }) do
      result = ChainReader::ConditionalTokensReader.balances(
        chain: @polygon, ct_address: CT_ADDRESS, owner: OWNER, position_ids: []
      )
      assert_equal [], result.values
      assert_nil result.block_number
    end
  end
end
