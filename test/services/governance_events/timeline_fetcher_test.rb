require "test_helper"

class GovernanceEvents::TimelineFetcherTest < ActiveSupport::TestCase
  setup do
    @contract = contracts(:uni_token)
    @contract.update!(abi: usdc_like_governance_abi)
    @latest_block = 25_000_000
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "returns empty when contract has no governance events" do
    @contract.update!(abi: [
      { "type" => "event", "name" => "Transfer",
        "inputs" => [ { "name" => "from", "type" => "address", "indexed" => true } ] }
    ])

    result = GovernanceEvents::TimelineFetcher.call(contract: @contract)
    assert result.success?
    assert_equal 0, result.total_events
    assert_equal 0, result.newly_fetched
  end

  test "fetches recent window when contract has never been scanned" do
    stub_logs(ownership_transferred_log(block_number: @latest_block - 100))

    result = with_eth_block_number { GovernanceEvents::TimelineFetcher.call(contract: @contract) }

    assert result.success?, result.error
    assert_equal 1, result.newly_fetched
    assert_equal 1, result.total_events
    assert_equal @latest_block, @contract.reload.governance_last_scanned_block
    assert_equal "OwnershipTransferred", result.events.first.event_name
    assert_equal "role_change", result.events.first.category
  end

  test "starts from last_scanned_block + 1 on incremental fetches" do
    @contract.update!(governance_last_scanned_block: @latest_block - 50)

    requested = []
    stub_request(:get, /api\.etherscan\.io/).to_return do |req|
      requested << req.uri.query_values
      logs_response([])
    end

    with_eth_block_number { GovernanceEvents::TimelineFetcher.call(contract: @contract) }

    assert requested.any?
    assert_equal (@latest_block - 49).to_s, requested.first["fromBlock"]
  end

  test "persists decoded args and human-readable summary" do
    stub_logs(ownership_transferred_log)

    result = with_eth_block_number { GovernanceEvents::TimelineFetcher.call(contract: @contract) }

    record = result.events.first
    assert_equal "0x" + "a" * 40, record.args["previousOwner"]
    assert_equal "0x" + "b" * 40, record.args["newOwner"]
    assert_equal "Owner: 0xaaaa…aaaa → 0xbbbb…bbbb", record.summary
  end

  test "is idempotent — re-running does not duplicate persisted events" do
    log = ownership_transferred_log
    stub_logs(log)

    with_eth_block_number { GovernanceEvents::TimelineFetcher.call(contract: @contract) }
    # reset last_scanned to force same window again
    @contract.update!(governance_last_scanned_block: nil)
    result = with_eth_block_number { GovernanceEvents::TimelineFetcher.call(contract: @contract) }

    assert_equal 1, GovernanceEvent.where(contract: @contract).count
    assert_equal 0, result.newly_fetched
  end

  test "scans every governance event type independently" do
    requested_topics = []
    stub_request(:get, /api\.etherscan\.io/).to_return do |req|
      requested_topics << req.uri.query_values["topic0"]
      logs_response([])
    end

    with_eth_block_number { GovernanceEvents::TimelineFetcher.call(contract: @contract) }

    # USDC-like ABI: 3 governance events (OwnershipTransferred + Pause + MinterConfigured)
    assert_equal 3, requested_topics.uniq.length
  end

  test "captures per-event-type failures as partial scan error, advances cursor anyway" do
    @contract.governance_events.create!(
      block_number: 100, tx_hash: "0xexisting", log_index: 0,
      event_name: "Pause", category: "lifecycle", summary: "Contract paused"
    )
    stub_request(:get, /api\.etherscan\.io/).to_return(
      status: 200,
      body: { status: "0", message: "NOTOK", result: "Invalid API Key" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = with_eth_block_number { GovernanceEvents::TimelineFetcher.call(contract: @contract) }

    refute result.success?
    assert_match(/partial scan:/, result.error)
    assert_match(/OwnershipTransferred/, result.error)
    assert_equal 1, result.events.length          # cached event still present
    assert_equal @latest_block, @contract.reload.governance_last_scanned_block
  end

  test "paginates within a window when results hit PAGE_SIZE" do
    page1 = Array.new(1000) { |i| ownership_transferred_log(block_number: 19_000_000 + i, tx_hash: "0xtx#{i}") }
    page2 = [ ownership_transferred_log(block_number: 19_001_000, tx_hash: "0xtxlast") ]

    request_count = 0
    stub_request(:get, /api\.etherscan\.io/).to_return do |req|
      next logs_response([]) unless req.uri.query_values["topic0"] == ownership_transferred_topic0

      request_count += 1
      case req.uri.query_values["page"]
      when "1" then logs_response(page1)
      when "2" then logs_response(page2)
      else logs_response([])
      end
    end

    result = with_eth_block_number { GovernanceEvents::TimelineFetcher.call(contract: @contract) }

    assert_equal 1001, result.newly_fetched
  end

  private

  def usdc_like_governance_abi
    [
      { "type" => "event", "name" => "OwnershipTransferred", "inputs" => [
        { "name" => "previousOwner", "type" => "address", "indexed" => true },
        { "name" => "newOwner", "type" => "address", "indexed" => true }
      ] },
      { "type" => "event", "name" => "Pause", "inputs" => [] },
      { "type" => "event", "name" => "MinterConfigured", "inputs" => [
        { "name" => "minter", "type" => "address", "indexed" => true },
        { "name" => "minterAllowedAmount", "type" => "uint256", "indexed" => false }
      ] }
    ]
  end

  def ownership_transferred_topic0
    @ownership_transferred_topic0 ||= ChainReader::EventDecoder.event_topic0(
      usdc_like_governance_abi.first
    )
  end

  def ownership_transferred_log(block_number: 19_000_000, tx_hash: "0xabc")
    {
      "address" => @contract.address,
      "topics" => [
        ownership_transferred_topic0,
        pad_address("0x" + "a" * 40),
        pad_address("0x" + "b" * 40)
      ],
      "data" => "0x",
      "blockNumber" => "0x" + block_number.to_s(16),
      "timeStamp" => "0x" + 1_700_000_000.to_s(16),
      "logIndex" => "0x0",
      "transactionHash" => tx_hash
    }
  end

  def pad_address(addr)
    "0x" + ("0" * 24) + addr.sub(/\A0x/, "")
  end

  def stub_logs(logs)
    logs = [ logs ] unless logs.is_a?(Array)
    stub_request(:get, /api\.etherscan\.io/).to_return do |req|
      # Only return logs for the OwnershipTransferred topic; other topics see empty results.
      if req.uri.query_values["topic0"] == ownership_transferred_topic0
        logs_response(logs)
      else
        logs_response([])
      end
    end
  end

  def logs_response(logs)
    body = { status: logs.empty? ? "0" : "1",
             message: logs.empty? ? "No records found" : "OK",
             result: logs }
    {
      status: 200,
      body: body.to_json,
      headers: { "Content-Type" => "application/json" }
    }
  end

  def with_eth_block_number(block_number = @latest_block, &block)
    stub_class_method(ChainReader::Base, :eth_block_number, ->(_chain) { block_number }, &block)
  end
end
