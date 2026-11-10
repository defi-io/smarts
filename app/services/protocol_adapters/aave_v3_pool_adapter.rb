module ProtocolAdapters
  # Aave V3 Pool (the lending market entry point). Reads the market straight
  # from the Pool proxy — getReservesList + getReserveData per asset — then
  # the aToken / variable-debt totalSupply for each reserve, all via
  # Multicall3. No UiPoolDataProvider: its address changes with every Aave
  # release, while the Pool proxy is stable per chain.
  class AaveV3PoolAdapter < Base
    # Canonical Aave V3 core market Pool proxies.
    # https://aave.com/docs/resources/addresses
    POOL_BY_CHAIN = {
      "eth"      => "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2",
      "base"     => "0xa238dd80c259a72e81d7e4664a9801593f98d1c5",
      "arbitrum" => "0x794a61358d6845594f94dc1db02a252b5b4814ad",
      "optimism" => "0x794a61358d6845594f94dc1db02a252b5b4814ad",
      "polygon"  => "0x794a61358d6845594f94dc1db02a252b5b4814ad",
      "bnb"      => "0x6807dc923806fe8fd134338eabca509979a7e0cb"
    }.freeze

    RAY = 10**27
    SECONDS_PER_YEAR = 31_536_000

    RESERVES_LIST_FN = { "name" => "getReservesList", "inputs" => [], "outputs" => [ { "type" => "address[]" } ] }.freeze

    # ReserveDataLegacy — what getReserveData returns on every V3 release
    # (3.0 through 3.4; stable-rate fields are zero after 3.2).
    RESERVE_DATA_FN = {
      "name" => "getReserveData",
      "inputs" => [ { "type" => "address" } ],
      "outputs" => [ {
        "type" => "tuple",
        "components" => [
          { "name" => "configuration",               "type" => "uint256" },
          { "name" => "liquidityIndex",              "type" => "uint128" },
          { "name" => "currentLiquidityRate",        "type" => "uint128" },
          { "name" => "variableBorrowIndex",         "type" => "uint128" },
          { "name" => "currentVariableBorrowRate",   "type" => "uint128" },
          { "name" => "currentStableBorrowRate",     "type" => "uint128" },
          { "name" => "lastUpdateTimestamp",         "type" => "uint40" },
          { "name" => "id",                          "type" => "uint16" },
          { "name" => "aTokenAddress",               "type" => "address" },
          { "name" => "stableDebtTokenAddress",      "type" => "address" },
          { "name" => "variableDebtTokenAddress",    "type" => "address" },
          { "name" => "interestRateStrategyAddress", "type" => "address" },
          { "name" => "accruedToTreasury",           "type" => "uint128" },
          { "name" => "unbacked",                    "type" => "uint128" },
          { "name" => "isolationModeTotalDebt",      "type" => "uint128" }
        ]
      } ]
    }.freeze

    ERC20_SYMBOL = { "name" => "symbol", "inputs" => [], "outputs" => [ { "type" => "string" } ] }.freeze
    ERC20_TOTAL_SUPPLY = { "name" => "totalSupply", "inputs" => [], "outputs" => [ { "type" => "uint256" } ] }.freeze

    def self.type_tag
      "aave_v3_pool"
    end

    # Address match only — zero RPC, and a fork reusing Aave's code at another
    # address is deliberately not treated as the Aave market.
    def self.matches?(contract)
      POOL_BY_CHAIN[contract.chain.slug] == contract.address.to_s.downcase
    end

    def self.pool_address_for(chain_slug)
      POOL_BY_CHAIN[chain_slug]
    end

    def protocol_name
      "Aave V3"
    end

    def display_name
      "Aave V3 Pool"
    end

    def panel_data
      Rails.cache.fetch(cache_key, expires_in: 60.seconds) { read_panel_data }
    end

    # Decodes the ReserveConfigurationMap bitfield.
    # https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/libraries/configuration/ReserveConfiguration.sol
    def self.decode_configuration(data)
      bits = ->(offset, width) { (data >> offset) & ((1 << width) - 1) }
      {
        ltv_bps:                   bits.(0, 16),
        liquidation_threshold_bps: bits.(16, 16),
        liquidation_bonus_bps:     bits.(32, 16),
        decimals:                  bits.(48, 8),
        active:                    bits.(56, 1) == 1,
        frozen:                    bits.(57, 1) == 1,
        borrowing_enabled:         bits.(58, 1) == 1,
        paused:                    bits.(60, 1) == 1,
        reserve_factor_bps:        bits.(64, 16),
        borrow_cap:                bits.(80, 36),
        supply_cap:                bits.(116, 36)
      }
    end

    # Aave stores per-second-compounded APRs in ray; the Aave UI shows APY.
    def self.ray_rate_to_apy(rate_ray)
      apr = rate_ray.to_f / RAY
      ((1 + apr / SECONDS_PER_YEAR)**SECONDS_PER_YEAR) - 1
    end

    private

    def cache_key
      "protocol_panel:aave_v3:v1:#{chain.slug}:#{contract.address}"
    end

    def read_panel_data
      assets = read_reserves_list
      return { error: "reserve list unreadable" } if assets.nil?

      reserves, block_number = read_reserves(assets)
      prices = fetch_usd_prices(assets)
      reserves.each { |r| attach_usd(r, prices) }
      reserves.sort_by! { |r| -(r[:supplied_usd] || -1) }

      {
        reserves: reserves,
        reserve_count: reserves.size,
        total_supplied_usd: sum_usd(reserves, :supplied_usd),
        total_borrowed_usd: sum_usd(reserves, :borrowed_usd),
        price_observed_at: oldest_price_timestamp(prices),
        block_number: block_number,
        fetched_at: Time.current
      }
    end

    def read_reserves_list
      batch = multicall([ call(contract.address, RESERVES_LIST_FN) ])
      result = batch.results.first
      result&.success ? result.values.first : nil
    end

    def read_reserves(assets)
      data_batch = multicall(assets.flat_map do |asset|
        [ call(contract.address, RESERVE_DATA_FN, [ asset ]), call(asset, ERC20_SYMBOL) ]
      end)

      raw = assets.each_with_index.filter_map do |asset, i|
        data, symbol = data_batch.results[2 * i, 2]
        next unless data.success

        [ asset, data.values.first, symbol.success ? symbol.values.first : "?" ]
      end

      supply_batch = multicall(raw.flat_map do |_asset, data, _symbol|
        [ call(data[8], ERC20_TOTAL_SUPPLY), call(data[10], ERC20_TOTAL_SUPPLY) ]
      end)

      reserves = raw.each_with_index.map do |(asset, data, symbol), i|
        a_supply, debt_supply = supply_batch.results[2 * i, 2]
        build_reserve(asset, symbol, data,
                      a_supply.success ? a_supply.values.first : nil,
                      debt_supply.success ? debt_supply.values.first : nil)
      end

      [ reserves, [ data_batch.block_number, supply_batch.block_number ].compact.min ]
    end

    def build_reserve(asset, symbol, data, a_supply, debt_supply)
      config = self.class.decode_configuration(data[0])
      scale = 10.0**config[:decimals]
      supplied = a_supply && a_supply / scale
      borrowed = debt_supply && debt_supply / scale

      {
        symbol: symbol,
        address: asset.downcase,
        decimals: config[:decimals],
        supply_apy: self.class.ray_rate_to_apy(data[2]),
        variable_borrow_apy: self.class.ray_rate_to_apy(data[4]),
        total_supplied: supplied,
        total_borrowed: borrowed,
        utilization: (supplied && borrowed && supplied > 0) ? borrowed / supplied : nil,
        ltv: config[:ltv_bps] / 10_000.0,
        liquidation_threshold: config[:liquidation_threshold_bps] / 10_000.0,
        # Stored as 10000 + bonus (10500 = 5% bonus); 0 when not collateral.
        liquidation_bonus: config[:liquidation_bonus_bps].zero? ? 0.0 : (config[:liquidation_bonus_bps] - 10_000) / 10_000.0,
        reserve_factor: config[:reserve_factor_bps] / 10_000.0,
        supply_cap: config[:supply_cap].zero? ? nil : config[:supply_cap],
        borrow_cap: config[:borrow_cap].zero? ? nil : config[:borrow_cap],
        active: config[:active],
        frozen: config[:frozen],
        paused: config[:paused],
        borrowing_enabled: config[:borrowing_enabled],
        a_token: data[8].downcase,
        variable_debt_token: data[10].downcase
      }
    end

    def attach_usd(reserve, prices)
      price = prices.dig(reserve[:address], "price")
      reserve[:price_usd] = price
      reserve[:supplied_usd] = (price && reserve[:total_supplied]) ? (reserve[:total_supplied] * price).round(2) : nil
      reserve[:borrowed_usd] = (price && reserve[:total_borrowed]) ? (reserve[:total_borrowed] * price).round(2) : nil
    end

    def sum_usd(reserves, key)
      values = reserves.filter_map { |r| r[key] }
      values.empty? ? nil : values.sum.round(2)
    end

    def fetch_usd_prices(addresses)
      DefiLlamaClient.fetch_prices(chain: chain, addresses: addresses)
    rescue DefiLlamaClient::Error => e
      Rails.logger.warn("[AaveV3PoolAdapter] price fetch failed: #{e.message}")
      {}
    end

    def oldest_price_timestamp(prices)
      stamps = prices.values.filter_map { |p| p["timestamp"] }
      stamps.empty? ? nil : Time.at(stamps.min)
    end

    def call(target, function, args = [])
      ChainReader::Multicall3Client::Call.new(target: target, function: function, args: args)
    end

    def multicall(calls)
      ChainReader::Multicall3Client.call(chain: chain, calls: calls)
    end
  end
end
