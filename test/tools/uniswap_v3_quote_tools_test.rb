require "test_helper"

class UniswapV3QuoteToolsTest < ActiveSupport::TestCase
  WETH = "0x4200000000000000000000000000000000000006"
  USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  TOKENS = { a: { address: WETH, symbol: "WETH", decimals: 18 }, b: { address: USDC, symbol: "USDC", decimals: 6 } }.freeze

  BEST = { fee: 500, fee_pct: "0.05%", pool: "0xd0b5", amount_out: 2111.24, amount_out_raw: 2_111_240_000,
           execution_price: 2111.24, spot_price: 2112.47, price_impact_pct: 0.0583, price_impact_ex_fee_pct: 0.0083,
           ticks_crossed: 1, gas_estimate: 77_175 }.freeze

  test "find_uniswap_v3_pools resolves slugs and labels the price direction" do
    seen = nil
    pools = ->(chain:, token_a:, token_b:) do
      seen = [ chain.slug, token_a, token_b ]
      ChainReader::UniswapV3Quoter::PoolsResult.new(
        tokens: TOKENS, block_number: 1,
        pools: [ { fee: 500, fee_pct: "0.05%", address: "0xd0b5", liquidity: 5, tick: 1, price_b_per_a: 2112.47, initialized: true } ]
      )
    end

    stub_class_method(ChainReader::UniswapV3Quoter, :pools, pools) do
      r = FindUniswapV3PoolsTool.payload(chain: "base", token_a: WETH, token_b: USDC.upcase.sub("0X", "0x"))
      assert_equal 1, r[:pool_count]
      assert_equal 2112.47, r[:pools].first["price (1 WETH in USDC)"]
      refute r[:pools].first.key?(:price_b_per_a)
      assert_match "not USD", r[:liquidity_note]
      assert r[:fetched_at].present?
    end
    assert_equal [ "base", WETH, USDC ], seen
  end

  test "quote_uniswap_v3_swap returns the best quote without raw integers" do
    seen = nil
    quote = ->(chain:, token_in:, token_out:, amount_in:, fee:) do
      seen = { chain: chain.slug, token_in: token_in, token_out: token_out, amount_in: amount_in, fee: fee }
      ChainReader::UniswapV3Quoter::QuoteResult.new(token_in: TOKENS[:a], token_out: TOKENS[:b], amount_in: 1.0,
                                                    quotes: [ BEST ], best: BEST, block_number: 2)
    end

    stub_class_method(ChainReader::UniswapV3Quoter, :quote, quote) do
      r = QuoteUniswapV3SwapTool.payload(chain: "base", token_in: WETH, token_out: USDC, amount_in: "1", fee: 500)
      assert_equal 2111.24, r[:best][:amount_out]
      assert_equal 0.0583, r[:best][:price_impact_pct]
      refute r[:best].key?(:amount_out_raw)
      assert_equal 2, r[:block_number]
      assert r[:fetched_at].present?
    end
    assert_equal({ chain: "base", token_in: WETH, token_out: USDC, amount_in: "1", fee: 500 }, seen)
  end

  test "quote_uniswap_v3_swap reports when every pool reverted" do
    failed = [ { fee: 500, error: "quote reverted" } ]
    quote = ->(**_) { ChainReader::UniswapV3Quoter::QuoteResult.new(token_in: TOKENS[:a], token_out: TOKENS[:b], amount_in: 1e9, quotes: failed, best: nil) }

    stub_class_method(ChainReader::UniswapV3Quoter, :quote, quote) do
      r = QuoteUniswapV3SwapTool.payload(chain: "base", token_in: WETH, token_out: USDC, amount_in: "1000000000")
      assert_match(/larger than available liquidity/, r[:error])
      assert_equal failed, r[:quotes]
    end
  end

  test "both tools reject unknown or unsupported chains, bad tokens and pass quoter errors through" do
    [ FindUniswapV3PoolsTool.payload(chain: "solana", token_a: WETH, token_b: USDC),
      QuoteUniswapV3SwapTool.payload(chain: "solana", token_in: WETH, token_out: USDC, amount_in: "1") ].each do |r|
      assert_equal "unknown chain: solana", r[:error]
    end
    assert_match(/not deployed on robinhood/, FindUniswapV3PoolsTool.payload(chain: "robinhood", token_a: WETH, token_b: USDC)[:error])
    assert_match(/curated slug/, QuoteUniswapV3SwapTool.payload(chain: "base", token_in: "WETH", token_out: USDC, amount_in: "1")[:error])

    stub_class_method(ChainReader::UniswapV3Quoter, :quote, ->(**_) { raise ChainReader::UniswapV3Quoter::Error, "amount_in must be positive" }) do
      assert_equal "amount_in must be positive", QuoteUniswapV3SwapTool.payload(chain: "base", token_in: WETH, token_out: USDC, amount_in: "0")[:error]
    end
  end
end
