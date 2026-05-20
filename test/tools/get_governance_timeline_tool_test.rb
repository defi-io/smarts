require "test_helper"

class GetGovernanceTimelineToolTest < ActiveSupport::TestCase
  setup do
    @tool = GetGovernanceTimelineTool
    @contract = contracts(:uni_token)
  end

  test "returns error for unknown chain" do
    result = @tool.payload(chain: "solana", address: "0x0")
    assert_equal "unknown chain: solana", result[:error]
  end

  test "returns error for unknown slug" do
    result = @tool.payload(slug: "totally-bogus-eth")
    assert_match(/unknown slug/, result[:error])
  end

  test "delegates to TimelineFetcher and shapes the payload" do
    fake_event = GovernanceEvent.new(
      block_number: 18_234_567,
      tx_hash: "0xabc",
      log_index: 0,
      event_name: "OwnershipTransferred",
      category: "role_change",
      summary: "Owner: 0xaaaa…aaaa → 0xbbbb…bbbb",
      args: { "previousOwner" => "0x" + "a" * 40, "newOwner" => "0x" + "b" * 40 },
      block_timestamp: Time.utc(2024, 8, 12, 15, 23, 0)
    )

    fake_result = GovernanceEvents::TimelineFetcher::Result.new(
      contract: @contract.address,
      chain: "eth",
      total_events: 1,
      newly_fetched: 1,
      latest_block: 25_000_000,
      events: [ fake_event ],
      error: nil
    )

    stub_class_method(GovernanceEvents::TimelineFetcher, :call, ->(**_) { fake_result }) do
      result = @tool.payload(chain: "eth", address: @contract.address)

      assert_equal @contract.address, result[:contract]
      assert_equal "eth", result[:chain]
      assert_equal 1, result[:total_events]
      assert_equal 1, result[:newly_fetched]
      assert_equal 25_000_000, result[:latest_block]
      assert_nil result[:category_filter]
      refute result.key?(:error)

      event = result[:events].first
      assert_equal 18_234_567, event[:block_number]
      assert_equal "OwnershipTransferred", event[:event]
      assert_equal "role_change", event[:category]
      assert_equal "Owner: 0xaaaa…aaaa → 0xbbbb…bbbb", event[:summary]
      assert_equal "2024-08-12T15:23:00Z", event[:timestamp]
      assert_equal "0x" + "a" * 40, event[:args]["previousOwner"]
    end
  end

  test "accepts Polymarket curated slugs for admin risk queries" do
    chain_slug, address = ContractSlugs.resolve("polymarket-ctf-exchange-v2-polygon")
    contract = Contract.create!(
      chain: Chain.find_by!(slug: chain_slug),
      address: address,
      name: "Polymarket Exchange",
      abi: []
    )
    fake_result = GovernanceEvents::TimelineFetcher::Result.new(
      contract: contract.address, chain: "polygon",
      total_events: 0, newly_fetched: 0, latest_block: 70_000_000,
      events: [], error: nil
    )

    stub_class_method(GovernanceEvents::TimelineFetcher, :call, ->(contract:) {
      assert_equal address, contract.address
      fake_result
    }) do
      result = @tool.payload(slug: "polymarket-ctf-exchange-v2-polygon")

      assert_equal address, result[:contract]
      assert_equal "polygon", result[:chain]
      assert_equal 70_000_000, result[:latest_block]
    end
  end

  test "filters by category when requested" do
    role_event = make_event(event_name: "OwnershipTransferred", category: "role_change")
    upgrade_event = make_event(event_name: "Upgraded", category: "upgrade", tx_hash: "0xdef")

    fake_result = GovernanceEvents::TimelineFetcher::Result.new(
      contract: @contract.address, chain: "eth",
      total_events: 2, newly_fetched: 2, latest_block: 25_000_000,
      events: [ role_event, upgrade_event ], error: nil
    )

    stub_class_method(GovernanceEvents::TimelineFetcher, :call, ->(**_) { fake_result }) do
      result = @tool.payload(chain: "eth", address: @contract.address, category: "upgrade")

      assert_equal "upgrade", result[:category_filter]
      assert_equal 1, result[:events].length
      assert_equal "Upgraded", result[:events].first[:event]
    end
  end

  test "surfaces TimelineFetcher errors but still returns cached events" do
    fake_event = make_event(event_name: "Pause", category: "lifecycle")
    fake_result = GovernanceEvents::TimelineFetcher::Result.new(
      contract: @contract.address, chain: "eth",
      total_events: 1, newly_fetched: 0, latest_block: nil,
      events: [ fake_event ], error: "Etherscan: down"
    )

    stub_class_method(GovernanceEvents::TimelineFetcher, :call, ->(**_) { fake_result }) do
      result = @tool.payload(chain: "eth", address: @contract.address)

      assert_equal "Etherscan: down", result[:error]
      assert_equal 1, result[:events].length
    end
  end

  test "limit slices the returned events" do
    events = Array.new(5) { |i| make_event(event_name: "Pause", category: "lifecycle", tx_hash: "0xt#{i}") }
    fake_result = GovernanceEvents::TimelineFetcher::Result.new(
      contract: @contract.address, chain: "eth",
      total_events: 5, newly_fetched: 5, latest_block: 25_000_000,
      events: events, error: nil
    )

    stub_class_method(GovernanceEvents::TimelineFetcher, :call, ->(**_) { fake_result }) do
      result = @tool.payload(chain: "eth", address: @contract.address, limit: 2)
      assert_equal 2, result[:events].length
    end
  end

  private

  def make_event(event_name:, category:, tx_hash: "0xabc")
    GovernanceEvent.new(
      block_number: 18_000_000,
      tx_hash: tx_hash,
      log_index: 0,
      event_name: event_name,
      category: category,
      summary: "summary",
      args: {},
      block_timestamp: Time.utc(2024, 1, 1)
    )
  end
end
