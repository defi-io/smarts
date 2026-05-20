require "test_helper"

class Polymarket::NegRiskActivityTest < ActiveSupport::TestCase
  setup do
    @polygon = chains(:polygon)
    @contract = Contract.new(chain: @polygon, address: "0xd91e80cf2e7be2e162c6513ced06f1dd0da35296")
  end

  test "groups events that exist on the contract; skips events absent from the ABI" do
    results = {
      "MarketPrepared" => success([
        event("MarketPrepared", { "marketId" => "0xmarket1" })
      ]),
      "MarketResolved" => success([
        event("MarketResolved", { "marketId" => "0xmarket2", "payouts" => [ 0, 1, 0 ] })
      ]),
      "QuestionPrepared" => error("event not in ABI: QuestionPrepared"),
      "QuestionResolved" => error("event not in ABI: QuestionResolved"),
      "OutcomeReported" => success([
        event("OutcomeReported", { "marketId" => "0xmarket1", "questionId" => "0xq", "outcome" => true })
      ])
    }

    with_stubs(results) do
      data = Polymarket::NegRiskActivity.call(contract: @contract)

      assert data[:ok]
      refute data[:empty]
      assert_includes data[:groups].keys, "MarketPrepared"
      assert_includes data[:groups].keys, "MarketResolved"
      assert_includes data[:groups].keys, "OutcomeReported"
      refute_includes data[:groups].keys, "QuestionPrepared"
      assert_equal [ 0, 1, 0 ], data[:groups]["MarketResolved"].first.payouts
      assert_equal true, data[:groups]["OutcomeReported"].first.outcome
      assert_includes data[:unavailable_events].keys, "QuestionPrepared"
    end
  end

  test "reports empty when the contract has none of the probed events recently" do
    results = Polymarket::NegRiskActivity::PROBE_EVENTS.each_with_object({}) do |name, acc|
      acc[name] = success([])
    end

    with_stubs(results) do
      data = Polymarket::NegRiskActivity.call(contract: @contract)
      assert data[:empty]
      assert_empty data[:groups]
    end
  end

  test "normalizes binary bytes32 market and question ids" do
    market_id = "0x" + ("11" * 32)
    question_id = "0x" + ("22" * 32)
    results = Polymarket::NegRiskActivity::PROBE_EVENTS.index_with { success([]) }
    results["OutcomeReported"] = success([
      event("OutcomeReported", {
        "marketId" => [ "11" * 32 ].pack("H*").b,
        "questionId" => [ "22" * 32 ].pack("H*").b,
        "outcome" => "false"
      })
    ])

    with_stubs(results) do
      item = Polymarket::NegRiskActivity.call(contract: @contract)[:groups]["OutcomeReported"].first

      assert_equal market_id, item.market_id
      assert_equal question_id, item.question_id
      assert_equal false, item.outcome
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

  def with_stubs(results_by_name, &block)
    fetcher = ->(contract:, event_name:, limit:) { results_by_name.fetch(event_name) }
    stub_class_method(ContractEvents::RecentFetcher, :call, fetcher, &block)
  end
end
