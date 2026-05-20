require "test_helper"

class Polymarket::UmaActivityTest < ActiveSupport::TestCase
  setup do
    @polygon = chains(:polygon)
    @contract = Contract.new(chain: @polygon, address: "0x2f5e3684cb1f318ec51b00edba38d79ac2c0aa9d")
  end

  test "shapes resolved, initialized, and disputed events with gamma labels" do
    results = {
      "QuestionResolved" => success([
        event("QuestionResolved", { "questionID" => "0xq1", "settledPrice" => "1000000000000000000", "payouts" => [ 1, 0 ] })
      ]),
      "QuestionInitialized" => success([
        event("QuestionInitialized", { "questionID" => "0xq2", "creator" => "0xcreator", "reward" => 5_000_000, "proposalBond" => 100_000_000 })
      ]),
      "QuestionFlagged" => success([
        event("QuestionFlagged", { "questionID" => "0xq3" })
      ])
    }
    index = {
      "0xq1" => { slug: "btc-200k", question: "Will BTC top $200k?", condition_id: "0xcond1" },
      "0xq2" => { slug: "fed-cut", question: "Fed cuts in June?", condition_id: "0xcond2" }
    }

    with_stubs(results, index) do
      data = Polymarket::UmaActivity.call(contract: @contract)

      assert data[:ok]
      assert_equal "Will BTC top $200k?", data[:resolved].first.market_label
      assert_equal "0xcond1", data[:resolved].first.condition_id
      assert_equal [ 1, 0 ], data[:resolved].first.payouts

      assert_equal "Fed cuts in June?", data[:initialized].first.market_label
      assert_equal "0xcreator", data[:initialized].first.creator

      disputed = data[:disputed].first
      assert_equal "0xq3", disputed.market_label # short id passes through truncate_id unchanged

      assert_equal [ :resolved, :disputed, :initialized ], data[:timeline].map(&:kind)
      assert_equal "Settled", data[:timeline].first.label
      assert_equal [ 1, 0 ], data[:timeline].first.payouts
    end
  end

  test "captures fetch errors per event name" do
    results = {
      "QuestionResolved" => error("etherscan 502"),
      "QuestionInitialized" => success([]),
      "QuestionFlagged" => success([])
    }

    with_stubs(results, {}) do
      data = Polymarket::UmaActivity.call(contract: @contract)
      assert_equal "etherscan 502", data[:errors]["QuestionResolved"]
    end
  end

  test "normalizes binary bytes32 question ids before lookup and display" do
    question_id = "0x" + ("ab" * 32)
    binary_question_id = [ "ab" * 32 ].pack("H*").b
    results = {
      "QuestionResolved" => success([]),
      "QuestionInitialized" => success([]),
      "QuestionFlagged" => success([
        event("QuestionFlagged", { "questionID" => binary_question_id })
      ])
    }
    captured_ids = nil
    lookup = ->(question_ids) do
      captured_ids = question_ids
      {
        question_id => {
          slug: "disputed-market",
          question: "Will this disputed market resolve yes?",
          condition_id: "0xcond"
        }
      }
    end

    stub_class_method(ContractEvents::RecentFetcher, :call, ->(contract:, event_name:, limit:) { results.fetch(event_name) }) do
      stub_class_method(PolymarketClient, :fetch_markets_by_question_ids, lookup) do
        data = Polymarket::UmaActivity.call(contract: @contract)

        assert_equal [ question_id ], captured_ids
        assert_equal question_id, data[:disputed].first.question_id
        assert_equal "Will this disputed market resolve yes?", data[:disputed].first.market_label
        assert_equal "disputed-market", data[:disputed].first.slug
      end
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

  def with_stubs(results_by_name, question_index, &block)
    fetcher = ->(contract:, event_name:, limit:) { results_by_name.fetch(event_name) }
    lookup  = ->(_question_ids) { question_index }

    stub_class_method(ContractEvents::RecentFetcher, :call, fetcher) do
      stub_class_method(PolymarketClient, :fetch_markets_by_question_ids, lookup, &block)
    end
  end
end
