require "test_helper"

# End-to-end flow for the USDC/WETH 0.05% Uniswap V3 pool. Satisfies the
# CLAUDE.md requirement for at least one E2E test. Stubs sit at our service
# boundaries (Etherscan, RPC via ChainReader, DefiLlama) so the eth gem's
# encoding/decoding still runs for real.
class UniswapV3PoolFlowTest < ActionDispatch::IntegrationTest
  POOL_ADDRESS = "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640"
  USDC_ADDRESS = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  WETH_ADDRESS = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
  V3_FACTORY   = "0x1f98431c8ad98523631ae4a59f267346ea31f984"

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "renders full V3 pool panel end-to-end for canonical pool address" do
    stub_etherscan_empty_pool

    factory_hex = "0x" + Eth::Abi.encode([ "address" ], [ V3_FACTORY ]).unpack1("H*")

    stub_class_method(ChainReader::Base, :eth_call_hex, ->(_chain, **_kwargs) { factory_hex }) do
      stub_class_method(ChainReader::Multicall3Client, :call, method(:fake_multicall)) do
        stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
          stub_class_method(DefiLlamaClient, :fetch_prices, ->(**_) { canned_prices }) do
            # POOL_ADDRESS has a slug (univ3-usdc-weth-eth), so hex URL 301s
            get contract_path(chain: "eth", address: POOL_ADDRESS)
            follow_redirect! if response.status == 301
          end
        end
      end
    end

    assert_response :success
    assert_match "Uniswap V3", response.body
    assert_match "USDC / WETH", response.body
    assert_match "0.05%", response.body
    assert_match(/1 WETH ≈ 2,32[12]\./, response.body)   # Computed price ≈ $2,321 per WETH
    assert_match(/\$100,13[0-9],[0-9]{3}/, response.body) # TVL ≈ $100.1M
    assert_match "USDC · 6 decimals", response.body
    assert_match "WETH · 18 decimals", response.body
    assert_match "198,819", response.body                 # current tick
    assert_match "via DefiLlama prices", response.body

    # Adapter-provided display name flows all the way up to page-level
    # identity — H1, <title>, OG title, breadcrumb. Locks the fix for the
    # "H1 says UniswapV3Pool instead of USDC/WETH 0.05%" bug.
    assert_select "h1", "USDC/WETH 0.05%"
    assert_match %r{<title>USDC/WETH 0\.05% on Ethereum — live on-chain contract docs \| smarts.md</title>}, response.body
    assert_match %r{<meta property="og:title" content="USDC/WETH 0\.05% on Ethereum — live on-chain contract docs \| smarts.md">}, response.body
    refute_match "UniswapV3Pool on Ethereum", response.body, "Solidity class name must not leak into the page title/breadcrumb"
  end

  test "renders pool panel gracefully when DefiLlama is down (no TVL, but price/fee/tokens shown)" do
    stub_etherscan_empty_pool
    factory_hex = "0x" + Eth::Abi.encode([ "address" ], [ V3_FACTORY ]).unpack1("H*")
    defillama_down = ->(**_) { raise DefiLlamaClient::Error, "429 rate limited" }

    stub_class_method(ChainReader::Base, :eth_call_hex, ->(_chain, **_kwargs) { factory_hex }) do
      stub_class_method(ChainReader::Multicall3Client, :call, method(:fake_multicall)) do
        stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
          stub_class_method(DefiLlamaClient, :fetch_prices, defillama_down) do
            # POOL_ADDRESS has a slug (univ3-usdc-weth-eth), so hex URL 301s
            get contract_path(chain: "eth", address: POOL_ADDRESS)
            follow_redirect! if response.status == 301
          end
        end
      end
    end

    assert_response :success
    assert_match "USDC / WETH", response.body
    assert_match "0.05%", response.body
    assert_match(/1 WETH ≈ 2,32[12]/, response.body)
    refute_match "TVL", response.body
    refute_match "via DefiLlama prices", response.body
  end

  private

  def fake_multicall(chain:, calls:)
    if calls.first.function["name"] == "token0"
      pool_state_results
    else
      tokens_and_reserves_results
    end
  end

  def pool_state_results
    [
      ChainReader::Multicall3Client::Result.new(success: true, values: [ USDC_ADDRESS ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ WETH_ADDRESS ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ 500 ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ 3_100_979_877_751_951_506 ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [
        [
          1_644_253_472_768_517_942_471_065_231_332_056,
          198_819,
          0, 0, 0, 0, false
        ]
      ])
    ]
  end

  def tokens_and_reserves_results
    [
      ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ 6 ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ 72_363_143_776_857 ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ "WETH" ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ 18 ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ 11_958_693_292_131_917_828_861 ])
    ]
  end

  def canned_prices
    {
      USDC_ADDRESS => { "price" => 1.0,     "symbol" => "USDC", "decimals" => 6,  "confidence" => 0.99 },
      WETH_ADDRESS => { "price" => 2322.29, "symbol" => "WETH", "decimals" => 18, "confidence" => 0.99 }
    }
  end

  def stub_etherscan_empty_pool
    source_body = {
      "status" => "1", "message" => "OK",
      "result" => [ {
        "ContractName" => "UniswapV3Pool",
        "CompilerVersion" => "v0.7.6",
        "SourceCode" => "contract UniswapV3Pool {}",
        "ABI" => "[]",
        "OptimizationUsed" => "1", "Runs" => "200",
        "EVMVersion" => "istanbul", "LicenseType" => "BUSL-1.1"
      } ]
    }
    abi_body = { "status" => "1", "message" => "OK", "result" => "[]" }

    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200, body: source_body.to_json, headers: { "Content-Type" => "application/json" }
    )
    stub_request(:get, /api\.etherscan\.io.*getabi/).to_return(
      status: 200, body: abi_body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end
end
