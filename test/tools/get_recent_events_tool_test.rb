require "test_helper"

class GetRecentEventsToolTest < ActiveSupport::TestCase
  setup do
    @tool = GetRecentEventsTool
    @contract = contracts(:uni_token)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @latest_block = 25_000_000
  end

  teardown do
    Rails.cache = @original_cache
  end

  # Tool now needs the latest block to compute its window; without stubbing
  # the call would hit a real RPC. Wraps the block-scoped class-method stub
  # to keep individual tests readable.
  def with_eth_block_number(block_number = @latest_block, &block)
    stub_class_method(ChainReader::Base, :eth_block_number, ->(_chain) { block_number }, &block)
  end

  # ──────────────────────────────────────────────
  # Resolution errors (delegated to ApplicationTool#resolve_contract)
  # ──────────────────────────────────────────────

  test "returns error for unknown chain" do
    result = @tool.payload(chain: "solana", address: "0x0")
    assert_equal "unknown chain: solana", result[:error]
  end

  test "returns error for unknown slug" do
    result = @tool.payload(slug: "totally-bogus-eth")
    assert_match(/unknown slug/, result[:error])
  end

  test "returns error when contract not indexed" do
    result = @tool.payload(chain: "eth", address: "0x" + "9" * 40)
    assert_match(/not indexed/, result[:error])
  end

  # ──────────────────────────────────────────────
  # Event-name filter
  # ──────────────────────────────────────────────

  test "returns error when event_name not in ABI" do
    stub_logs([])
    result = @tool.payload(chain: "eth", address: @contract.address, event_name: "Mint")
    assert_match(/event not in ABI: Mint/, result[:error])
  end

  test "passes topic0 filter to Etherscan when event_name given" do
    expected_topic0 = ChainReader::EventDecoder.event_topic0(transfer_event_abi)
    seen_query = nil

    stub_request(:get, /api\.etherscan\.io/).to_return do |req|
      seen_query = req.uri.query
      { status: 200, body: empty_logs_body, headers: { "Content-Type" => "application/json" } }
    end

    with_eth_block_number do
      @tool.payload(chain: "eth", address: @contract.address, event_name: "Transfer", limit: 5)
    end

    assert_includes seen_query.to_s, "topic0=#{expected_topic0}",
                    "event_name filter must translate to a topic0 server-side filter"
  end

  # ──────────────────────────────────────────────
  # Recent-window logic (the bug fix that this whole tool depends on)
  # ──────────────────────────────────────────────

  test "constrains query window to the last RECENT_BLOCK_WINDOW blocks" do
    seen_query = nil
    stub_request(:get, /api\.etherscan\.io/).to_return do |req|
      seen_query = req.uri.query
      { status: 200, body: empty_logs_body, headers: { "Content-Type" => "application/json" } }
    end

    with_eth_block_number(25_000_000) do
      @tool.payload(chain: "eth", address: @contract.address)
    end

    expected_from = 25_000_000 - GetRecentEventsTool::RECENT_BLOCK_WINDOW
    assert_includes seen_query.to_s, "fromBlock=#{expected_from}",
                    "must constrain fromBlock so Etherscan's page 1 contains recent events, not earliest"
    assert_includes seen_query.to_s, "toBlock=25000000",
                    "toBlock should be the explicit latest block (not the string 'latest')"
  end

  test "fromBlock floors at 0 for chains/contracts younger than the window" do
    seen_query = nil
    stub_request(:get, /api\.etherscan\.io/).to_return do |req|
      seen_query = req.uri.query
      { status: 200, body: empty_logs_body, headers: { "Content-Type" => "application/json" } }
    end

    with_eth_block_number(500) do
      @tool.payload(chain: "eth", address: @contract.address)
    end

    assert_includes seen_query.to_s, "fromBlock=0"
  end

  # ──────────────────────────────────────────────
  # Decoding paths
  # ──────────────────────────────────────────────

  test "decodes a Transfer event with named indexed and non-indexed args" do
    from_addr = "0x" + "a" * 40
    to_addr   = "0x" + "b" * 40
    amount    = 1000

    log = sample_log(
      topics: [
        ChainReader::EventDecoder.event_topic0(transfer_event_abi),
        pad_address(from_addr),
        pad_address(to_addr)
      ],
      data: pad_uint(amount),
      block_number: 19_000_000,
      log_index: 5,
      tx_hash: "0xdeadbeef",
      timestamp: 1_700_000_000
    )
    stub_logs([ log ])

    result = with_eth_block_number { @tool.payload(chain: "eth", address: @contract.address, limit: 1) }

    assert_equal 1, result[:count]
    event = result[:events].first
    assert_equal "Transfer",     event[:event]
    assert_equal 19_000_000,     event[:block_number]
    assert_equal "0xdeadbeef",   event[:tx_hash]
    assert_equal 5,              event[:log_index]
    assert_equal "2023-11-14T22:13:20Z", event[:timestamp]
    assert_equal from_addr, event[:args]["from"]
    assert_equal to_addr,   event[:args]["to"]
    assert_equal amount,    event[:args]["amount"]
  end

  test "timestamp of 0 (or missing) renders as nil, not 1970-01-01" do
    log = sample_log(
      topics: [ ChainReader::EventDecoder.event_topic0(transfer_event_abi),
                pad_address("0x" + "a" * 40),
                pad_address("0x" + "b" * 40) ],
      data: pad_uint(1),
      timestamp: 0
    )
    stub_logs([ log ])

    result = with_eth_block_number { @tool.payload(chain: "eth", address: @contract.address, limit: 1) }
    assert_nil result[:events].first[:timestamp],
               "Etherscan sometimes returns timeStamp=0 — must surface as nil, not Unix epoch"
  end

  test "log with nil/missing topics is rendered as Unknown without crashing" do
    log = sample_log(topics: nil, data: "0x", block_number: 19_000_000)
    stub_logs([ log ])

    result = with_eth_block_number { @tool.payload(chain: "eth", address: @contract.address, limit: 1) }
    event = result[:events].first
    assert_equal "Unknown", event[:event]
    assert_nil event[:topic0]
  end

  test "labels unknown topic0 as 'Unknown' and surfaces raw fields" do
    unknown_topic = "0x" + "c" * 64
    log = sample_log(topics: [ unknown_topic ], data: "0x", block_number: 19_000_001)
    stub_logs([ log ])

    result = with_eth_block_number { @tool.payload(chain: "eth", address: @contract.address, limit: 1) }

    event = result[:events].first
    assert_equal "Unknown",     event[:event]
    assert_equal unknown_topic, event[:topic0]
    assert_equal "0x",          event[:raw_data]
  end

  test "returns empty events list when Etherscan reports no records" do
    stub_request(:get, /api\.etherscan\.io/).to_return(
      status: 200,
      body: { status: "0", message: "No records found", result: [] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = with_eth_block_number { @tool.payload(chain: "eth", address: @contract.address, limit: 10) }
    assert_equal 0, result[:count]
    assert_equal [], result[:events]
  end

  # ──────────────────────────────────────────────
  # Schema stability for AI consumers
  # ──────────────────────────────────────────────

  test "exposes contract, chain, and event_filter for AI consumers" do
    stub_logs([])
    result = with_eth_block_number { @tool.payload(chain: "eth", address: @contract.address) }

    assert_equal @contract.address, result[:contract]
    assert_equal "eth",             result[:chain]
    assert result.key?(:event_filter), "event_filter key must always be present (nil when no filter)"
    assert_nil result[:event_filter]
  end

  test "always fetches a full Etherscan page so the client-side slice has the newest" do
    seen_query = nil
    stub_request(:get, /api\.etherscan\.io/).to_return do |req|
      seen_query = req.uri.query
      { status: 200, body: empty_logs_body, headers: { "Content-Type" => "application/json" } }
    end

    with_eth_block_number do
      @tool.payload(chain: "eth", address: @contract.address, limit: 5)
    end

    # Etherscan ignores `sort=desc`; if we only asked for `limit` records,
    # we'd get the *earliest* `limit`. Always pulling the full page lets
    # the client-side reverse+slice surface the most recent ones.
    assert_includes seen_query.to_s, "offset=#{GetRecentEventsTool::ETHERSCAN_MAX_OFFSET}"
  end

  test "result list is reversed and capped to limit" do
    # Three logs in ascending block order — what Etherscan actually returns.
    logs = [ 19_000_001, 19_000_002, 19_000_003 ].map do |block|
      sample_log(
        topics: [ ChainReader::EventDecoder.event_topic0(transfer_event_abi),
                  pad_address("0x" + "a" * 40),
                  pad_address("0x" + "b" * 40) ],
        data:   pad_uint(1),
        block_number: block,
        log_index: 0,
        tx_hash: "0xtx#{block}",
        timestamp: 1_700_000_000
      )
    end
    stub_logs(logs)

    result = with_eth_block_number { @tool.payload(chain: "eth", address: @contract.address, limit: 2) }

    assert_equal 2, result[:count], "must respect limit after reversal"
    blocks = result[:events].map { |e| e[:block_number] }
    assert_equal [ 19_000_003, 19_000_002 ], blocks,
                 "newest-first means descending block_number, taking the latest `limit`"
  end

  test "limit larger than MAX_LIMIT is clamped before slicing" do
    logs = (1..200).map do |i|
      sample_log(
        topics: [ ChainReader::EventDecoder.event_topic0(transfer_event_abi),
                  pad_address("0x" + "a" * 40),
                  pad_address("0x" + "b" * 40) ],
        data:   pad_uint(i),
        block_number: 19_000_000 + i,
        log_index: 0,
        tx_hash: "0x#{i.to_s(16).rjust(2, '0')}",
        timestamp: 1_700_000_000
      )
    end
    stub_logs(logs)

    result = with_eth_block_number { @tool.payload(chain: "eth", address: @contract.address, limit: 9_999) }

    assert_equal GetRecentEventsTool::MAX_LIMIT, result[:count]
  end

  test "surfaces fetch errors as a top-level error when both Etherscan and RPC fail" do
    # Etherscan failure → fetcher transparently falls back to RPC `eth_getLogs`.
    # We stub RPC to also fail so the user-facing top-level error path is
    # exercised. The message comes from the RPC error since it's the last
    # thing tried before giving up.
    stub_request(:get, /api\.etherscan\.io/).to_return(
      status: 200,
      body: { status: "0", message: "NOTOK", result: "Invalid API Key" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    stub_class_method(ChainReader::Base, :eth_get_logs,
      ->(_chain, **_) { raise ChainReader::Base::RpcError, "rpc down" }) do
      result = with_eth_block_number { @tool.payload(chain: "eth", address: @contract.address) }
      assert_match(/rpc down/, result[:error])
    end
  end

  # ──────────────────────────────────────────────
  # Slug input
  # ──────────────────────────────────────────────

  test "accepts a slug instead of chain+address" do
    Contract.create!(chain: chains(:ethereum),
                     address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
                     name: "Uni",
                     abi: @contract.abi)
    stub_logs([])

    result = with_eth_block_number { @tool.payload(slug: "uni-eth") }
    assert_equal 0, result[:count]
    assert_equal "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984", result[:contract]
  end

  private

  def transfer_event_abi
    @contract.events.find { |e| e["name"] == "Transfer" }
  end

  def pad_address(addr)
    "0x" + ("0" * 24) + addr.sub(/\A0x/, "")
  end

  def pad_uint(value)
    "0x" + value.to_s(16).rjust(64, "0")
  end

  def sample_log(topics:, data:, block_number: 19_000_000, log_index: 0, tx_hash: "0xabc", timestamp: 1_700_000_000)
    {
      "address" => @contract.address,
      "topics"  => topics,
      "data"    => data,
      "blockNumber" => "0x" + block_number.to_s(16),
      "blockHash"   => "0x" + "0" * 64,
      "timeStamp"   => "0x" + timestamp.to_s(16),
      "gasPrice"    => "0x0",
      "gasUsed"     => "0x0",
      "logIndex"    => "0x" + log_index.to_s(16),
      "transactionHash"  => tx_hash,
      "transactionIndex" => "0x0"
    }
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

  def empty_logs_body
    { status: "0", message: "No records found", result: [] }.to_json
  end
end
