require "test_helper"

class Polymarket::CtfActivityTest < ActiveSupport::TestCase
  setup do
    @polygon = chains(:polygon)
    @contract = Contract.new(chain: @polygon, address: "0x4d97dcd97ec945f40cf65f87097ace5ea0476045")
  end

  test "shapes resolutions, preparations, and redemptions into role payload" do
    results = {
      "ConditionResolution" => success([
        event("ConditionResolution", { "conditionId" => "0xabc", "questionId" => "0xq1", "oracle" => "0x0", "outcomeSlotCount" => 2, "payoutNumerators" => [ 1, 0 ] })
      ]),
      "ConditionPreparation" => success([
        event("ConditionPreparation", { "conditionId" => "0xdef", "questionId" => "0xq2", "oracle" => "0x0", "outcomeSlotCount" => 3 })
      ]),
      "PayoutRedemption" => success([
        event("PayoutRedemption", { "redeemer" => "0xred", "conditionId" => "0xabc", "payout" => 25_000_000 })
      ])
    }

    with_stubs(results, { "0xabc" => { slug: "trump-2024", question: "Will Trump win 2024?" } }) do
      data = Polymarket::CtfActivity.call(contract: @contract)

      assert data[:ok]
      assert_equal "Will Trump win 2024?", data[:resolutions].first.market_label
      assert_equal [ 1, 0 ], data[:resolutions].first.payouts
      assert_equal "0xdef", data[:preparations].first.condition_id
      assert_equal BigDecimal("25"), data[:redemptions].first.payout
      assert_equal "0xred", data[:redemptions].first.redeemer
    end
  end

  test "uses truncated condition_id when gamma lookup yields no match" do
    results = {
      "ConditionResolution" => success([
        event("ConditionResolution", { "conditionId" => "0x1234567890abcdef", "questionId" => "0xq", "oracle" => "0x0", "outcomeSlotCount" => 2, "payoutNumerators" => [ 0, 1 ] })
      ]),
      "ConditionPreparation" => success([]),
      "PayoutRedemption" => success([])
    }

    with_stubs(results, {}) do
      data = Polymarket::CtfActivity.call(contract: @contract)
      label = data[:resolutions].first.market_label
      assert_match(/0x1234/, label)
      assert_match(/cdef/, label)
    end
  end

  test "normalizes binary bytes32 ids before condition lookup and display" do
    condition_id = "0x" + ("ab" * 32)
    question_id = "0x" + ("cd" * 32)
    binary_condition_id = [ "ab" * 32 ].pack("H*").b
    binary_question_id = [ "cd" * 32 ].pack("H*").b
    results = {
      "ConditionResolution" => success([
        event("ConditionResolution", {
          "conditionId" => binary_condition_id,
          "questionId" => binary_question_id,
          "oracle" => "0x0",
          "outcomeSlotCount" => 2,
          "payoutNumerators" => [ 1, 0 ]
        })
      ]),
      "ConditionPreparation" => success([]),
      "PayoutRedemption" => success([
        event("PayoutRedemption", { "conditionId" => binary_condition_id, "payout" => 1_000_000 })
      ])
    }
    captured_ids = nil
    lookup = ->(condition_ids) do
      captured_ids = condition_ids
      { condition_id => { slug: "binary-condition", question: "Binary condition?" } }
    end

    stub_class_method(ContractEvents::RecentFetcher, :call, ->(contract:, event_name:, limit:) { results.fetch(event_name) }) do
      stub_class_method(PolymarketClient, :fetch_markets_by_condition_ids, lookup) do
        data = Polymarket::CtfActivity.call(contract: @contract)

        assert_equal [ condition_id ], captured_ids
        assert_equal condition_id, data[:resolutions].first.condition_id
        assert_equal question_id, data[:resolutions].first.question_id
        assert_equal "Binary condition?", data[:resolutions].first.market_label
        assert_equal condition_id, data[:redemptions].first.condition_id
      end
    end
  end

  test "captures per-event errors without crashing the panel" do
    results = {
      "ConditionResolution" => error("rpc timeout"),
      "ConditionPreparation" => success([]),
      "PayoutRedemption" => success([])
    }

    with_stubs(results, {}) do
      data = Polymarket::CtfActivity.call(contract: @contract)
      assert_equal "rpc timeout", data[:errors]["ConditionResolution"]
      assert_empty data[:resolutions]
    end
  end

  private

  def event(name, args, timestamp: 1.minute.ago.utc.iso8601)
    ContractEvents::RecentFetcher::Event.new(
      event: name, args: args, block_number: 70_000_000, tx_hash: "0xtx", log_index: 0, timestamp: timestamp
    )
  end

  def success(events)
    ContractEvents::RecentFetcher::Result.new(
      contract: @contract.address, chain: "polygon", event_filter: nil,
      latest_block: 70_000_100, from_block: 69_995_100, count: events.size,
      events: events, error: nil
    )
  end

  def error(message)
    ContractEvents::RecentFetcher::Result.new(
      contract: @contract.address, chain: "polygon", event_filter: nil,
      latest_block: nil, from_block: nil, count: 0, events: [], error: message
    )
  end

  def with_stubs(results_by_name, condition_index, &block)
    fetcher = ->(contract:, event_name:, limit:) { results_by_name.fetch(event_name) }
    lookup  = ->(_condition_ids) { condition_index }

    stub_class_method(ContractEvents::RecentFetcher, :call, fetcher) do
      stub_class_method(PolymarketClient, :fetch_markets_by_condition_ids, lookup, &block)
    end
  end
end
