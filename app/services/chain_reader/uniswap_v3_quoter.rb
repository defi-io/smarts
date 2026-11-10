require "bigdecimal"
require "bigdecimal/util"

module ChainReader
  # Uniswap V3 pool discovery (Factory.getPool across fee tiers) and swap
  # quotes (QuoterV2.quoteExactInputSingle) with price impact against the
  # pool's spot price. Everything goes through Multicall3: one batch for pool
  # addresses + token metadata, one for pool state + quotes.
  #
  #   ChainReader::UniswapV3Quoter.pools(chain:, token_a:, token_b:)
  #     → PoolsResult(tokens: {a:, b:}, pools: [...], block_number:)
  #   ChainReader::UniswapV3Quoter.quote(chain:, token_in:, token_out:, amount_in: "1.5", fee: nil)
  #     → QuoteResult(token_in:, token_out:, amount_in:, quotes: [...], best:, block_number:)
  class UniswapV3Quoter
    class Error < StandardError; end

    # Canonical Uniswap Labs deployments.
    # https://docs.uniswap.org/contracts/v3/reference/deployments
    DEPLOYMENTS = {
      "eth"      => { factory: "0x1f98431c8ad98523631ae4a59f267346ea31f984", quoter: "0x61ffe014ba17989e743c5f6cb21bf9697530b21e" },
      "arbitrum" => { factory: "0x1f98431c8ad98523631ae4a59f267346ea31f984", quoter: "0x61ffe014ba17989e743c5f6cb21bf9697530b21e" },
      "optimism" => { factory: "0x1f98431c8ad98523631ae4a59f267346ea31f984", quoter: "0x61ffe014ba17989e743c5f6cb21bf9697530b21e" },
      "polygon"  => { factory: "0x1f98431c8ad98523631ae4a59f267346ea31f984", quoter: "0x61ffe014ba17989e743c5f6cb21bf9697530b21e" },
      "base"     => { factory: "0x33128a8fc17869897dce68ed026d694621f6fdfd", quoter: "0x3d4e44eb1374240ce5f1b871ab261cd16335b76a" },
      "bnb"      => { factory: "0xdb1d10011ad0ff90774d0c6bb92e5c5c8b4461f7", quoter: "0x78d78e420da98ad378d7799be8f4af69033eb077" }
    }.freeze

    FEE_TIERS = [ 100, 500, 3000, 10_000 ].freeze
    ZERO_ADDRESS = "0x0000000000000000000000000000000000000000".freeze

    GET_POOL = {
      "name" => "getPool",
      "inputs" => [ { "type" => "address" }, { "type" => "address" }, { "type" => "uint24" } ],
      "outputs" => [ { "type" => "address" } ]
    }.freeze

    QUOTE_EXACT_INPUT_SINGLE = {
      "name" => "quoteExactInputSingle",
      "inputs" => [ {
        "type" => "tuple",
        "components" => [
          { "name" => "tokenIn",           "type" => "address" },
          { "name" => "tokenOut",          "type" => "address" },
          { "name" => "amountIn",          "type" => "uint256" },
          { "name" => "fee",               "type" => "uint24" },
          { "name" => "sqrtPriceLimitX96", "type" => "uint160" }
        ]
      } ],
      "outputs" => [
        { "name" => "amountOut",               "type" => "uint256" },
        { "name" => "sqrtPriceX96After",       "type" => "uint160" },
        { "name" => "initializedTicksCrossed", "type" => "uint32" },
        { "name" => "gasEstimate",             "type" => "uint256" }
      ]
    }.freeze

    SLOT0 = {
      "name" => "slot0", "inputs" => [],
      "outputs" => [ { "type" => "uint160" }, { "type" => "int24" }, { "type" => "uint16" }, { "type" => "uint16" },
                     { "type" => "uint16" }, { "type" => "uint8" }, { "type" => "bool" } ]
    }.freeze
    LIQUIDITY = { "name" => "liquidity", "inputs" => [], "outputs" => [ { "type" => "uint128" } ] }.freeze
    SYMBOL    = { "name" => "symbol",    "inputs" => [], "outputs" => [ { "type" => "string" } ] }.freeze
    DECIMALS  = { "name" => "decimals",  "inputs" => [], "outputs" => [ { "type" => "uint8" } ] }.freeze

    PoolsResult = Struct.new(:tokens, :pools, :block_number, keyword_init: true)
    QuoteResult = Struct.new(:token_in, :token_out, :amount_in, :quotes, :best, :block_number, keyword_init: true)

    def self.supported?(chain)
      DEPLOYMENTS.key?(chain.slug)
    end

    def self.pools(chain:, token_a:, token_b:)
      new(chain).pools(token_a.downcase, token_b.downcase)
    end

    def self.quote(chain:, token_in:, token_out:, amount_in:, fee: nil)
      new(chain).quote(token_in.downcase, token_out.downcase, amount_in, fee)
    end

    # Spot price of 1 token0 in token1 units from sqrtPriceX96.
    def self.price_token1_per_token0(sqrt_price_x96, decimals0, decimals1)
      return nil if sqrt_price_x96.to_i.zero?

      ((sqrt_price_x96.to_d / (2**96))**2 * (BigDecimal(10)**(decimals0 - decimals1))).to_f
    end

    def initialize(chain)
      @chain = chain
      @deployment = DEPLOYMENTS[chain.slug] or raise Error, "Uniswap V3 is not deployed on #{chain.slug}; supported: #{DEPLOYMENTS.keys.join(', ')}"
    end

    def pools(token_a, token_b)
      raise Error, "token_a and token_b must differ" if token_a == token_b

      tokens, addresses, block_a = discover(token_a, token_b)
      states, block_b = read_pool_states(addresses)

      pools = addresses.filter_map do |fee, address|
        state = states[address]
        next unless state

        {
          fee: fee,
          fee_pct: fee_pct(fee),
          address: address,
          liquidity: state[:liquidity],
          tick: state[:tick],
          price_b_per_a: spot_price(state[:sqrt_price_x96], token_a, token_b, tokens),
          initialized: !state[:sqrt_price_x96].to_i.zero?
        }
      end

      PoolsResult.new(tokens: { a: tokens[token_a], b: tokens[token_b] }, pools: pools, block_number: [ block_a, block_b ].compact.min)
    end

    def quote(token_in, token_out, amount_in, fee)
      raise Error, "token_in and token_out must differ" if token_in == token_out
      raise Error, "unsupported fee tier #{fee}; use one of #{FEE_TIERS.join(', ')}" if fee && !FEE_TIERS.include?(fee.to_i)

      tokens, addresses, block_a = discover(token_in, token_out)
      addresses = addresses.select { |f, _| f == fee.to_i } if fee
      raise Error, "no Uniswap V3 pool for this pair#{" at fee #{fee}" if fee} on #{@chain.slug}" if addresses.empty?

      decimals_in = tokens[token_in][:decimals]
      raw_in = to_raw(amount_in, decimals_in)

      calls = addresses.flat_map do |f, address|
        [ call(address, SLOT0), call(@deployment[:quoter], QUOTE_EXACT_INPUT_SINGLE, [ [ token_in, token_out, raw_in, f, 0 ] ]) ]
      end
      batch = multicall(calls)

      quotes = addresses.each_with_index.filter_map do |(f, address), i|
        slot0, quoted = batch.results[2 * i, 2]
        build_quote(f, address, slot0, quoted, raw_in, token_in, token_out, tokens)
      end

      QuoteResult.new(
        token_in: tokens[token_in],
        token_out: tokens[token_out],
        amount_in: from_raw(raw_in, decimals_in),
        quotes: quotes.sort_by { |q| -(q[:amount_out_raw] || -1) },
        best: quotes.select { |q| q[:amount_out_raw] }.max_by { |q| q[:amount_out_raw] },
        block_number: [ block_a, batch.block_number ].compact.min
      )
    end

    private

    # Batch 1: getPool for every fee tier + symbol/decimals for both tokens.
    # Returns [tokens_by_address, {fee => pool_address}, block_number].
    def discover(token_a, token_b)
      calls = FEE_TIERS.map { |fee| call(@deployment[:factory], GET_POOL, [ token_a, token_b, fee ]) }
      calls += [ token_a, token_b ].flat_map { |t| [ call(t, SYMBOL), call(t, DECIMALS) ] }
      batch = multicall(calls)
      r = batch.results

      tokens = [ token_a, token_b ].each_with_index.to_h do |t, i|
        sym, dec = r[FEE_TIERS.size + 2 * i, 2]
        raise Error, "#{t} is not an ERC-20 on #{@chain.slug} (decimals() failed)" unless dec.success

        [ t, { address: t, symbol: sym.success ? sym.values.first : "?", decimals: dec.values.first } ]
      end

      addresses = FEE_TIERS.each_with_index.filter_map do |fee, i|
        address = r[i].success ? r[i].values.first.to_s.downcase : ZERO_ADDRESS
        [ fee, address ] unless address == ZERO_ADDRESS
      end.to_h

      [ tokens, addresses, batch.block_number ]
    end

    def read_pool_states(addresses)
      return [ {}, nil ] if addresses.empty?

      batch = multicall(addresses.values.flat_map { |a| [ call(a, SLOT0), call(a, LIQUIDITY) ] })
      states = addresses.values.each_with_index.to_h do |address, i|
        slot0, liq = batch.results[2 * i, 2]
        state = slot0.success && liq.success ? { sqrt_price_x96: slot0.values[0], tick: slot0.values[1], liquidity: liq.values.first } : nil
        [ address, state ]
      end
      [ states.compact, batch.block_number ]
    end

    def build_quote(fee, address, slot0, quoted, raw_in, token_in, token_out, tokens)
      base = { fee: fee, fee_pct: fee_pct(fee), pool: address }
      return base.merge(error: "quote reverted (pool has too little liquidity for this size?)") unless quoted.success

      amount_out_raw, _sqrt_after, ticks_crossed, gas_estimate = quoted.values
      amount_in = from_raw(raw_in, tokens[token_in][:decimals])
      amount_out = from_raw(amount_out_raw, tokens[token_out][:decimals])
      spot = slot0.success ? spot_price(slot0.values[0], token_in, token_out, tokens) : nil
      execution = amount_in.positive? ? amount_out / amount_in : nil

      base.merge(
        amount_out: amount_out,
        amount_out_raw: amount_out_raw,
        execution_price: execution,
        spot_price: spot,
        # Total shortfall vs spot (includes the LP fee).
        price_impact_pct: impact(execution, spot),
        # Shortfall caused by moving the price alone, with the LP fee removed.
        price_impact_ex_fee_pct: impact(execution, spot && spot * (1 - fee / 1_000_000.0)),
        ticks_crossed: ticks_crossed,
        gas_estimate: gas_estimate
      )
    end

    # Price of 1 `from` in `to` units.
    def spot_price(sqrt_price_x96, from, to, tokens)
      token0, token1 = [ from, to ].sort
      p = self.class.price_token1_per_token0(sqrt_price_x96, tokens[token0][:decimals], tokens[token1][:decimals])
      return nil if p.nil? || p.zero?

      from == token0 ? p : 1.0 / p
    end

    def impact(execution, reference)
      return nil if execution.nil? || reference.nil? || reference.zero?

      ((1 - execution / reference) * 100).round(4)
    end

    def to_raw(amount, decimals)
      value = BigDecimal(amount.to_s)
      raise Error, "amount_in must be positive" unless value.positive?

      (value * (BigDecimal(10)**decimals)).to_i
    rescue ArgumentError
      raise Error, "amount_in is not a number: #{amount.inspect}"
    end

    def from_raw(raw, decimals)
      (BigDecimal(raw) / (BigDecimal(10)**decimals)).to_f
    end

    def fee_pct(fee)
      pct = fee / 10_000.0
      pct == pct.to_i ? "#{pct.to_i}%" : format("%g%%", pct)
    end

    def call(target, function, args = [])
      Multicall3Client::Call.new(target: target, function: function, args: args)
    end

    def multicall(calls)
      Multicall3Client.call(chain: @chain, calls: calls)
    end
  end
end
