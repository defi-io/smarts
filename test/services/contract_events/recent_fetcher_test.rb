require "test_helper"

class ContractEvents::RecentFetcherTest < ActiveSupport::TestCase
  setup do
    @contract = contracts(:uni_token)
    @latest_block = 25_000_000
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "returns decoded events newest first inside the recent window" do
    logs = [ 19_000_001, 19_000_002, 19_000_003 ].map do |block|
      sample_transfer_log(block_number: block, tx_hash: "0xtx#{block}")
    end
    stub_logs(logs)

    result = with_eth_block_number do
      ContractEvents::RecentFetcher.call(contract: @contract, limit: 2)
    end

    assert result.success?
    assert_equal @contract.address, result.contract
    assert_equal "eth", result.chain
    assert_equal @latest_block, result.latest_block
    assert_equal @latest_block - ContractEvents::RecentFetcher::RECENT_BLOCK_WINDOW, result.from_block
    assert_equal [ 19_000_003, 19_000_002 ], result.events.map(&:block_number)
    assert_equal "Transfer", result.events.first.event
    assert_equal "0x" + "a" * 40, result.events.first.args["from"]
  end

  test "returns an error result when event filter is absent from ABI" do
    result = ContractEvents::RecentFetcher.call(contract: @contract, event_name: "Swap")

    refute result.success?
    assert_equal "event not in ABI: Swap", result.error
    assert_equal [], result.events
  end

  test "surfaces unknown topics without crashing" do
    unknown_topic = "0x" + "c" * 64
    stub_logs([ sample_log(topics: [ unknown_topic ], data: "0x") ])

    result = with_eth_block_number do
      ContractEvents::RecentFetcher.call(contract: @contract, limit: 1)
    end

    event = result.events.first
    assert event.unknown?
    assert_equal unknown_topic, event.topic0
    assert_equal "0x", event.raw_data
  end

  test "surfaces Etherscan errors as result errors" do
    stub_request(:get, /api\.etherscan\.io/).to_return(
      status: 200,
      body: { status: "0", message: "NOTOK", result: "Invalid API Key" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = with_eth_block_number do
      ContractEvents::RecentFetcher.call(contract: @contract)
    end

    refute result.success?
    assert_match(/Etherscan:/, result.error)
  end

  private

  def with_eth_block_number(block_number = @latest_block, &block)
    stub_class_method(ChainReader::Base, :eth_block_number, ->(_chain) { block_number }, &block)
  end

  def transfer_event_abi
    @contract.events.find { |event| event["name"] == "Transfer" }
  end

  def sample_transfer_log(block_number: 19_000_000, tx_hash: "0xabc")
    sample_log(
      topics: [
        ChainReader::EventDecoder.event_topic0(transfer_event_abi),
        pad_address("0x" + "a" * 40),
        pad_address("0x" + "b" * 40)
      ],
      data: pad_uint(1_000),
      block_number: block_number,
      tx_hash: tx_hash
    )
  end

  def sample_log(topics:, data:, block_number: 19_000_000, tx_hash: "0xabc", timestamp: 1_700_000_000)
    {
      "address" => @contract.address,
      "topics" => topics,
      "data" => data,
      "blockNumber" => "0x" + block_number.to_s(16),
      "timeStamp" => "0x" + timestamp.to_s(16),
      "logIndex" => "0x0",
      "transactionHash" => tx_hash
    }
  end

  def pad_address(addr)
    "0x" + ("0" * 24) + addr.sub(/\A0x/, "")
  end

  def pad_uint(value)
    "0x" + value.to_s(16).rjust(64, "0")
  end

  def stub_logs(logs)
    body = { status: logs.empty? ? "0" : "1",
             message: logs.empty? ? "No records found" : "OK",
             result: logs }
    stub_request(:get, /api\.etherscan\.io/).to_return(
      status: 200,
      body: body.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end
end
