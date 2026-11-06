require "test_helper"

class BlockscoutClientTest < ActiveSupport::TestCase
  setup do
    @chain = chains(:robinhood)
    @client = BlockscoutClient.new(@chain)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "fetch_contract_info returns parsed data from getsourcecode alone" do
    stub = stub_source(result_row)

    info = @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")

    assert_equal "WETH", info[:name]
    assert_equal "v0.8.24+commit.e11b9ed9", info[:compiler_version]
    assert_equal "totalSupply", info[:abi].first["name"]
    assert_nil info[:implementation_address]
    assert_not_nil info[:verified_at]
    assert_requested stub, times: 1, times_msg: "Blockscout inlines the ABI — no second getabi round-trip"
    assert_not_requested(:get, /getabi/)
  end

  test "fetch_contract_info extracts NatSpec from source" do
    stub_source(result_row(source_code: <<~SOL))
      contract WETH {
        /// @notice Total tokens in circulation.
        function totalSupply() external view returns (uint256) {}
      }
    SOL

    info = @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")

    assert_equal "Total tokens in circulation.", info[:natspec].dig("functions", "totalSupply", "notice")
  end

  test "accepts an already-parsed ABI array" do
    stub_source(result_row(abi: [ { "type" => "function", "name" => "totalSupply" } ]))

    info = @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")

    assert_equal "totalSupply", info[:abi].first["name"]
  end

  # Blockscout has no `ABI: "Contract source code not verified"` sentinel: an
  # unverified address returns status "1" with a row holding only `Address`.
  test "raises NotVerifiedError when the result row carries no ABI" do
    stub_source({ "Address" => "0x0000000000000000000000000000000000000001" })

    assert_raises(BlockscoutClient::NotVerifiedError) do
      @client.fetch_contract_info("0x0000000000000000000000000000000000000001")
    end
  end

  test "raises NotVerifiedError on the Etherscan-style sentinel too" do
    stub_source({ "ABI" => "Contract source code not verified" })

    assert_raises(BlockscoutClient::NotVerifiedError) do
      @client.fetch_contract_info("0x0000000000000000000000000000000000000001")
    end
  end

  test "NotVerifiedError is the shared ExplorerClient error, so existing rescues catch it" do
    assert_equal ExplorerClient::NotVerifiedError, BlockscoutClient::NotVerifiedError
    assert_equal ExplorerClient::Error, BlockscoutClient::Error
    assert_operator BlockscoutClient::NotVerifiedError, :<, ExplorerClient::Error
  end

  test "resolves a proxy via IsProxy + ImplementationAddress" do
    proxy = "0x1111111111111111111111111111111111111111"
    impl  = "0x2222222222222222222222222222222222222222"

    stub_source_for(proxy, result_row(name: "ERC1967Proxy", is_proxy: true, implementation: impl))
    stub_source_for(impl, result_row(name: "StockTokenV2"))

    info = @client.fetch_contract_info(proxy)

    assert_equal "StockTokenV2", info[:name]
    assert_equal impl, info[:implementation_address]
  end

  # Some Blockscout versions serialize IsProxy as a JSON string, not a boolean.
  test "casts a string IsProxy" do
    proxy = "0x1111111111111111111111111111111111111111"
    impl  = "0x2222222222222222222222222222222222222222"

    stub_source_for(proxy, result_row(name: "ERC1967Proxy", is_proxy: "true", implementation: impl))
    stub_source_for(impl, result_row(name: "StockTokenV2"))

    assert_equal "StockTokenV2", @client.fetch_contract_info(proxy)[:name]
  end

  test "treats a string 'false' IsProxy as not a proxy" do
    stub_source(result_row(is_proxy: "false"))

    info = @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")

    assert_nil info[:implementation_address]
    assert_equal "WETH", info[:name]
  end

  test "falls back to ImplementationAddresses when the singular key is absent" do
    proxy = "0x1111111111111111111111111111111111111111"
    impl  = "0x2222222222222222222222222222222222222222"
    row = result_row(name: "ERC1967Proxy", is_proxy: true).merge("ImplementationAddresses" => [ impl ])

    stub_source_for(proxy, row)
    stub_source_for(impl, result_row(name: "StockTokenV2"))

    assert_equal impl, @client.fetch_contract_info(proxy)[:implementation_address]
  end

  # Blockscout splits multi-file verifications; the Source tab must still see
  # every file, so they're re-assembled into the map source_files() parses.
  test "re-assembles AdditionalSources into a parseable multi-file source" do
    row = result_row(source_code: "contract WETH {}").merge(
      "FileName" => "contracts/WETH.sol",
      "AdditionalSources" => [
        { "Filename" => "contracts/interfaces/IWETH.sol", "SourceCode" => "interface IWETH {}" },
        { "Filename" => "contracts/lib/Address.sol", "SourceCode" => "library Address {}" }
      ]
    )
    stub_source(row)

    info = @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")
    files = ApplicationController.helpers.source_files(info[:source_code])

    assert_equal [ "contracts/WETH.sol", "contracts/interfaces/IWETH.sol", "contracts/lib/Address.sol" ],
                 files.map { |f| f[:path] }
    assert_equal "interface IWETH {}", files.second[:content]
  end

  test "leaves a single-file source as plain Solidity" do
    stub_source(result_row(source_code: "contract WETH {}"))

    info = @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")

    assert_equal "contract WETH {}", info[:source_code]
    assert_equal [ "contract.sol" ], ApplicationController.helpers.source_files(info[:source_code]).map { |f| f[:path] }
  end

  # Public Blockscout instances answer bursts with HTTP 429 and status "0".
  test "raises Error when the instance rate-limits" do
    stub_request(:get, /robinhoodchain\.blockscout\.com/).to_return(
      status: 429,
      body: { "message" => "Too many requests.", "result" => nil, "status" => "0" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    err = assert_raises(BlockscoutClient::Error) do
      @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")
    end
    assert_match(/Blockscout API error/, err.message)
    assert_match(/Too many requests/, err.message)
  end

  # Cloudflare answers UA-less requests with an HTML challenge page.
  test "raises a clear Error instead of a JSON crash on a non-JSON response" do
    stub_request(:get, /robinhoodchain\.blockscout\.com/).to_return(
      status: 200, body: "<!DOCTYPE html><title>Just a moment...</title>", headers: { "Content-Type" => "text/html" }
    )

    err = assert_raises(BlockscoutClient::Error) do
      @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")
    end
    assert_match(/non-JSON response/, err.message)
  end

  test "wraps network failures in Error so the contract page degrades cleanly" do
    stub_request(:get, /robinhoodchain\.blockscout\.com/).to_timeout

    err = assert_raises(BlockscoutClient::Error) do
      @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")
    end
    assert_match(/Blockscout request failed/, err.message)
  end

  test "sends a User-Agent so Cloudflare doesn't serve the bot challenge" do
    seen_ua = nil
    stub_request(:get, /robinhoodchain\.blockscout\.com/).to_return do |req|
      seen_ua = req.headers["User-Agent"]
      { status: 200, body: { "status" => "1", "message" => "OK", "result" => [ result_row ] }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end

    @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")

    assert_equal ExplorerClient::USER_AGENT, seen_ua
  end

  test "does not send Etherscan's chainid parameter" do
    seen_query = nil
    stub_request(:get, /robinhoodchain\.blockscout\.com/).to_return do |req|
      seen_query = req.uri.query
      { status: 200, body: { "status" => "1", "message" => "OK", "result" => [ result_row ] }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end

    @client.fetch_contract_info("0x0bd7d308f8e1639fab988df18a8011f41eacad73")

    refute_includes seen_query.to_s, "chainid"
  end

  test "logs_supported? is false so callers fall back to RPC eth_getLogs" do
    assert_not @client.logs_supported?
  end

  private

  def result_row(name: "WETH", source_code: "contract WETH {}", abi: nil, is_proxy: false, implementation: nil)
    row = {
      "Address" => "0x0bd7d308f8e1639fab988df18a8011f41eacad73",
      "ContractName" => name,
      "CompilerVersion" => "v0.8.24+commit.e11b9ed9",
      "SourceCode" => source_code,
      "ABI" => abi || '[{"type":"function","name":"totalSupply"}]',
      "IsProxy" => is_proxy,
      "OptimizationUsed" => "true"
    }
    row["ImplementationAddress"] = implementation if implementation
    row
  end

  def stub_source(row)
    stub_request(:get, /robinhoodchain\.blockscout\.com.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ row ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_source_for(address, row)
    stub_request(:get, /robinhoodchain\.blockscout\.com.*getsourcecode/)
      .with(query: hash_including(address: address))
      .to_return(
        status: 200,
        body: { "status" => "1", "message" => "OK", "result" => [ row ] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end
end
