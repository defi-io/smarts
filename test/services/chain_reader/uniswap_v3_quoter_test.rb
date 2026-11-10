require "test_helper"

class ChainReader::UniswapV3QuoterTest < ActiveSupport::TestCase
  Quoter = ChainReader::UniswapV3Quoter
  Result = ChainReader::Multicall3Client::Result

  WETH = "0x4200000000000000000000000000000000000006" # token0 (lower address)
  USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  POOLS = { 500 => "0x00000000000000000000000000000000000p0500".tr("p", "a"),
            3000 => "0x00000000000000000000000000000000000p3000".tr("p", "a"),
            10_000 => "0x0000000000000000000000000000000000p10000".tr("p", "a") }.freeze

  # 1 WETH = 2000 USDC  →  raw token1/token0 = 2000 * 10^(6-18)
  SQRT_PRICE = Integer(Math.sqrt(2000 * 10.0**-12) * 2**96)

  QUOTES = { 500 => 1_998_000_000, 3000 => 1_990_000_000 }.freeze # 10_000 reverts

  setup { @chain = chains(:base) }

  def fake_multicall(decimals_ok: true)
    lambda do |chain:, calls:|
      results = calls.map do |c|
        case c.function["name"]
        when "getPool"
          Result.new(success: true, values: [ POOLS.fetch(c.args[2], Quoter::ZERO_ADDRESS) ])
        when "symbol"   then Result.new(success: true, values: [ c.target == WETH ? "WETH" : "USDC" ])
        when "decimals"
          decimals_ok ? Result.new(success: true, values: [ c.target == WETH ? 18 : 6 ]) : Result.new(success: false, error: "execution reverted")
        when "slot0"     then Result.new(success: true, values: [ SQRT_PRICE, 200_000, 0, 1, 1, 0, true ])
        when "liquidity" then Result.new(success: true, values: [ 10**18 ])
        when "quoteExactInputSingle"
          token_in, _out, amount_in, fee, _limit = c.args.first
          raise "unexpected direction" unless token_in == WETH && amount_in == 10**18

          out = QUOTES[fee]
          out ? Result.new(success: true, values: [ out, SQRT_PRICE, 1, 80_000 ]) : Result.new(success: false, error: "execution reverted")
        end
      end
      ChainReader::Multicall3Client::Batch.new(block_number: 40_000_000, results: results)
    end
  end

  def with_chain(**opts, &block)
    stub_class_method(ChainReader::Multicall3Client, :call, fake_multicall(**opts), &block)
  end

  test "pools lists one pool per existing fee tier with spot price" do
    with_chain do
      result = Quoter.pools(chain: @chain, token_a: USDC, token_b: WETH)

      assert_equal [ 500, 3000, 10_000 ], result.pools.map { |p| p[:fee] }, "the 0.01% tier has no pool"
      assert_equal %w[0.05% 0.3% 1%], result.pools.map { |p| p[:fee_pct] }
      assert_equal "USDC", result.tokens[:a][:symbol]
      assert_in_delta 1.0 / 2000, result.pools.first[:price_b_per_a], 1e-9, "price is 1 token_a (USDC) in token_b (WETH)"
      assert_equal 10**18, result.pools.first[:liquidity]
      assert_equal 40_000_000, result.block_number
    end
  end

  test "quote ranks pools by amount out and computes price impact vs spot" do
    with_chain do
      result = Quoter.quote(chain: @chain, token_in: WETH, token_out: USDC, amount_in: "1")

      assert_equal 1.0, result.amount_in
      assert_equal [ 500, 3000, 10_000 ], result.quotes.map { |q| q[:fee] }
      best = result.best
      assert_equal 500, best[:fee]
      assert_equal 1998.0, best[:amount_out]
      assert_in_delta 2000.0, best[:spot_price], 1e-6
      assert_in_delta 0.1, best[:price_impact_pct], 1e-3, "1998 vs 2000 spot"
      assert_in_delta 0.05, best[:price_impact_ex_fee_pct], 1e-3, "minus the 0.05% LP fee"
      assert_equal 80_000, best[:gas_estimate]
      assert_match(/reverted/, result.quotes.last[:error], "the 1% tier quote reverted")
    end
  end

  test "quote can be pinned to one fee tier" do
    with_chain do
      result = Quoter.quote(chain: @chain, token_in: WETH, token_out: USDC, amount_in: 1, fee: 3000)
      assert_equal [ 3000 ], result.quotes.map { |q| q[:fee] }
      assert_equal 1990.0, result.best[:amount_out]
    end
  end

  test "quote errors: missing tier pool, bad fee, bad amount, same token, non-ERC-20" do
    with_chain do
      assert_raises(Quoter::Error) { Quoter.quote(chain: @chain, token_in: WETH, token_out: USDC, amount_in: 1, fee: 100) }
      assert_raises(Quoter::Error) { Quoter.quote(chain: @chain, token_in: WETH, token_out: USDC, amount_in: 1, fee: 42) }
      assert_raises(Quoter::Error) { Quoter.quote(chain: @chain, token_in: WETH, token_out: USDC, amount_in: "0") }
      assert_raises(Quoter::Error) { Quoter.quote(chain: @chain, token_in: WETH, token_out: USDC, amount_in: "lots") }
      assert_raises(Quoter::Error) { Quoter.quote(chain: @chain, token_in: WETH, token_out: WETH, amount_in: 1) }
    end
    with_chain(decimals_ok: false) do
      error = assert_raises(Quoter::Error) { Quoter.pools(chain: @chain, token_a: WETH, token_b: USDC) }
      assert_match(/not an ERC-20/, error.message)
    end
  end

  test "unsupported chains are rejected up front" do
    refute Quoter.supported?(chains(:robinhood))
    assert_raises(Quoter::Error) { Quoter.pools(chain: chains(:robinhood), token_a: WETH, token_b: USDC) }
  end
end
