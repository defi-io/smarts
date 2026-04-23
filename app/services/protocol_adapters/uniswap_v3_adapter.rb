require "bigdecimal"
require "bigdecimal/util"

module ProtocolAdapters
  class UniswapV3Adapter < Base
    # Uniswap V3 Factory addresses per chain. Pool.factory() must equal this
    # for the contract to be a canonical V3 pool on that chain.
    FACTORY_BY_CHAIN = {
      "eth"      => "0x1f98431c8ad98523631ae4a59f267346ea31f984",
      "arbitrum" => "0x1f98431c8ad98523631ae4a59f267346ea31f984",
      "optimism" => "0x1f98431c8ad98523631ae4a59f267346ea31f984",
      "polygon"  => "0x1f98431c8ad98523631ae4a59f267346ea31f984",
      "base"     => "0x33128a8fc17869897dce68ed026d694621f6fdfd"
    }.freeze

    FACTORY_FN = { "name" => "factory", "inputs" => [], "outputs" => [ { "type" => "address" } ] }

    POOL_STATE_ABI = [
      { "name" => "token0",    "inputs" => [], "outputs" => [ { "type" => "address" } ] },
      { "name" => "token1",    "inputs" => [], "outputs" => [ { "type" => "address" } ] },
      { "name" => "fee",       "inputs" => [], "outputs" => [ { "type" => "uint24" } ] },
      { "name" => "liquidity", "inputs" => [], "outputs" => [ { "type" => "uint128" } ] },
      { "name" => "slot0", "inputs" => [], "outputs" => [ {
        "type" => "tuple",
        "components" => [
          { "name" => "sqrtPriceX96",               "type" => "uint160" },
          { "name" => "tick",                       "type" => "int24" },
          { "name" => "observationIndex",           "type" => "uint16" },
          { "name" => "observationCardinality",     "type" => "uint16" },
          { "name" => "observationCardinalityNext", "type" => "uint16" },
          { "name" => "feeProtocol",                "type" => "uint8" },
          { "name" => "unlocked",                   "type" => "bool" }
        ]
      } ] }
    ].freeze

    ERC20_SYMBOL = { "name" => "symbol", "inputs" => [], "outputs" => [ { "type" => "string" } ] }
    ERC20_DECIMALS = { "name" => "decimals", "inputs" => [], "outputs" => [ { "type" => "uint8" } ] }
    ERC20_BALANCE_OF = {
      "name" => "balanceOf",
      "inputs"  => [ { "type" => "address" } ],
      "outputs" => [ { "type" => "uint256" } ]
    }

    def self.type_tag
      "uniswap_v3_pool"
    end

    def self.matches?(contract)
      factory = fetch_factory(contract)
      expected = FACTORY_BY_CHAIN[contract.chain.slug]
      return false if factory.nil? || expected.nil?

      factory.downcase == expected
    rescue StandardError
      false
    end

    def self.fetch_factory(contract)
      data = ChainReader::Base.selector("factory()")
      hex = ChainReader::Base.eth_call_hex(contract.chain, to: contract.address, data: data)
      Eth::Abi.decode([ "address" ], ChainReader::Base.hex_to_bytes(hex)).first
    end

    def protocol_name
      "Uniswap V3"
    end

    # "USDC/WETH 0.05%" — composed from token0/token1/fee already loaded into
    # panel_data (cached 60s, so calling from the view helper doesn't add RPC).
    # Returns nil on any data gap so contract_display_name falls back through
    # the rest of its chain (on-chain name → symbol → contract.name).
    def display_name
      data = panel_data
      return nil if data[:error]

      t0 = data.dig(:token0, :symbol)
      t1 = data.dig(:token1, :symbol)
      fee = data[:fee_pct]
      return nil if t0.blank? || t1.blank? || fee.blank? || t0 == "?" || t1 == "?"

      "#{t0}/#{t1} #{fee}"
    end

    def panel_data
      Rails.cache.fetch(cache_key, expires_in: 60.seconds) { read_panel_data }
    end

    private

    def cache_key
      "protocol_panel:uniswap_v3:#{chain.slug}:#{contract.address}"
    end

    def read_panel_data
      pool = read_pool_state
      return { error: "pool state unreadable" } unless pool

      tokens = read_tokens_and_reserves(pool[:token0], pool[:token1], contract.address)
      t0 = tokens[:token0]
      t1 = tokens[:token1]

      price_1_per_0 = price_token1_per_token0(pool[:sqrt_price_x96], t0[:decimals], t1[:decimals])
      usd_prices = fetch_usd_prices(pool[:token0], pool[:token1])
      tvl_usd = compute_tvl(t0, t1, usd_prices, pool[:token0], pool[:token1])

      {
        token0: t0.merge(address: pool[:token0]),
        token1: t1.merge(address: pool[:token1]),
        fee_pct: format_fee(pool[:fee]),
        liquidity: pool[:liquidity],
        tick: pool[:tick],
        sqrt_price_x96: pool[:sqrt_price_x96],
        price_1_per_0: price_1_per_0,
        price_0_per_1: (price_1_per_0 && price_1_per_0 > 0) ? 1.0 / price_1_per_0 : nil,
        tvl_usd: tvl_usd,
        usd_prices: usd_prices
      }
    end

    def read_pool_state
      calls = POOL_STATE_ABI.map do |fn|
        ChainReader::Multicall3Client::Call.new(target: contract.address, function: fn)
      end
      results = ChainReader::Multicall3Client.call(chain: chain, calls: calls)

      return nil unless results.all?(&:success)

      token0, token1, fee, liquidity, slot0 = results.map { |r| r.values.first }

      {
        token0: token0,
        token1: token1,
        fee: fee,
        liquidity: liquidity,
        sqrt_price_x96: slot0[0],
        tick: slot0[1]
      }
    end

    def read_tokens_and_reserves(addr0, addr1, pool_addr)
      calls = [
        ChainReader::Multicall3Client::Call.new(target: addr0, function: ERC20_SYMBOL),
        ChainReader::Multicall3Client::Call.new(target: addr0, function: ERC20_DECIMALS),
        ChainReader::Multicall3Client::Call.new(target: addr0, function: ERC20_BALANCE_OF, args: [ pool_addr ]),
        ChainReader::Multicall3Client::Call.new(target: addr1, function: ERC20_SYMBOL),
        ChainReader::Multicall3Client::Call.new(target: addr1, function: ERC20_DECIMALS),
        ChainReader::Multicall3Client::Call.new(target: addr1, function: ERC20_BALANCE_OF, args: [ pool_addr ])
      ]
      r = ChainReader::Multicall3Client.call(chain: chain, calls: calls)

      {
        token0: {
          symbol:   r[0].success ? r[0].values.first : "?",
          decimals: r[1].success ? r[1].values.first : 18,
          reserve:  r[2].success ? r[2].values.first : nil
        },
        token1: {
          symbol:   r[3].success ? r[3].values.first : "?",
          decimals: r[4].success ? r[4].values.first : 18,
          reserve:  r[5].success ? r[5].values.first : nil
        }
      }
    end

    def fetch_usd_prices(*addresses)
      DefiLlamaClient.fetch_prices(chain: chain, addresses: addresses)
    rescue DefiLlamaClient::Error => e
      Rails.logger.warn("[UniswapV3Adapter] price fetch failed: #{e.message}")
      {}
    end

    def compute_tvl(t0, t1, usd_prices, addr0, addr1)
      return nil unless t0[:reserve] && t1[:reserve]

      p0 = usd_prices.dig(addr0.downcase, "price")
      p1 = usd_prices.dig(addr1.downcase, "price")
      return nil unless p0 && p1

      tvl0 = t0[:reserve].to_f / (10.0**t0[:decimals].to_i) * p0
      tvl1 = t1[:reserve].to_f / (10.0**t1[:decimals].to_i) * p1
      (tvl0 + tvl1).round(2)
    end

    def format_fee(fee_raw)
      # fee is expressed in hundredths of a basis point: 500 = 0.05%, 3000 = 0.3%, 10000 = 1%
      pct = fee_raw.to_f / 10_000.0
      pct == pct.to_i ? "#{pct.to_i}%" : format("%g%%", pct)
    end

    # Price of 1 token0 in terms of token1, adjusted for decimals.
    # https://blog.uniswap.org/uniswap-v3-math-primer
    # price = (sqrtPriceX96 / 2^96)^2 * 10^(decimals0 - decimals1)
    def price_token1_per_token0(sqrt_price_x96, dec0, dec1)
      return nil if sqrt_price_x96.to_i.zero?

      q96 = 2**96
      ratio = (sqrt_price_x96.to_d / q96) ** 2
      adjustment = BigDecimal(10) ** (dec0.to_i - dec1.to_i)
      (ratio * adjustment).to_f
    rescue StandardError
      nil
    end
  end
end
