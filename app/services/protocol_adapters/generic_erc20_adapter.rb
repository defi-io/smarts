require "bigdecimal"
require "bigdecimal/util"
require "set"

module ProtocolAdapters
  class GenericErc20Adapter < Base
    # 4-byte selectors for the 6 required ERC-20 functions.
    # totalSupply, balanceOf, transfer, transferFrom, approve, allowance.
    ERC20_REQUIRED_SELECTORS = %w[
      0x18160ddd 0x70a08231 0xa9059cbb 0x23b872dd 0x095ea7b3 0xdd62ed3e
    ].freeze

    ERC20_NAME         = { "name" => "name",        "inputs" => [], "outputs" => [ { "type" => "string" } ] }.freeze
    ERC20_SYMBOL       = { "name" => "symbol",      "inputs" => [], "outputs" => [ { "type" => "string" } ] }.freeze
    ERC20_DECIMALS     = { "name" => "decimals",    "inputs" => [], "outputs" => [ { "type" => "uint8" } ] }.freeze
    ERC20_TOTAL_SUPPLY = { "name" => "totalSupply", "inputs" => [], "outputs" => [ { "type" => "uint256" } ] }.freeze

    # Optional zero-arg admin/status functions found on centralized stablecoins
    # (USDC's FiatToken, USDT's TetherToken, etc). Each probed only if present
    # in the ABI. Ordered by severity so the view can render in priority order.
    #
    # `abi:` uses string keys for compatibility with ChainReader helpers which
    # expect `fn_abi["name"]`, `fn_abi["inputs"]`, `fn_abi["outputs"]`.
    def self.admin_spec(name, output_type, label, severity = nil)
      {
        abi: { "name" => name, "inputs" => [], "outputs" => [ { "type" => output_type } ] },
        label: label,
        severity: severity
      }
    end

    ADMIN_STATUS_FUNCTIONS = [
      admin_spec("paused",          "bool",    "Paused",     :critical),
      admin_spec("deprecated",      "bool",    "Deprecated", :critical),
      admin_spec("upgradedAddress", "address", "Upgraded to")
    ].freeze

    ADMIN_ROLE_FUNCTIONS = [
      admin_spec("owner",        "address", "Owner"),
      admin_spec("masterMinter", "address", "Master minter"),
      admin_spec("pauser",       "address", "Pauser"),
      admin_spec("blacklister",  "address", "Blacklister"),
      admin_spec("rescuer",      "address", "Rescuer")
    ].freeze

    ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"

    # Issuer whitelist keyed by chain slug → lowercase address. Covers the big
    # blue-chip tokens on each supported chain. L2 variants that are bridged
    # from mainnet (not issued directly by the named entity) get a "(bridged)"
    # suffix so the badge stays honest — MakerDAO for example only mints DAI
    # on Ethereum; L2 DAI is a bridge receipt.
    CIRCLE   = { name: "Circle",         url: "https://www.circle.com/" }.freeze
    TETHER   = { name: "Tether",         url: "https://tether.to/" }.freeze
    MAKER    = { name: "MakerDAO",       url: "https://makerdao.com/" }.freeze
    MAKER_B  = { name: "MakerDAO (bridged)", url: "https://makerdao.com/" }.freeze
    WETH_I   = { name: "Wrapped Ether",  url: nil }.freeze
    WBTC_I   = { name: "BitGo (WBTC)",   url: "https://wbtc.network/" }.freeze
    WBTC_B   = { name: "BitGo (bridged)", url: "https://wbtc.network/" }.freeze
    POLY_M   = { name: "Polygon (WPOL)", url: "https://polygon.technology/" }.freeze

    ISSUERS = {
      "eth" => {
        "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" => CIRCLE,  # USDC
        "0xdac17f958d2ee523a2206206994597c13d831ec7" => TETHER,  # USDT
        "0x6b175474e89094c44da98b954eedeac495271d0f" => MAKER,   # DAI
        "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" => WETH_I,  # WETH
        "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599" => WBTC_I   # WBTC
      },
      "base" => {
        "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913" => CIRCLE,  # USDC (native)
        "0x50c5725949a6f0c72e6c4a641f24049a917db0cb" => MAKER_B, # DAI  (bridged)
        "0x4200000000000000000000000000000000000006" => WETH_I   # WETH (canonical)
      },
      "arbitrum" => {
        "0xaf88d065e77c8cc2239327c5edb3a432268e5831" => CIRCLE,  # USDC (native)
        "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9" => TETHER,  # USDT (native)
        "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1" => MAKER_B, # DAI  (bridged)
        "0x82af49447d8a07e3bd95bd0d56f35241523fbab1" => WETH_I,  # WETH
        "0x2f2a2543b76a4166549f7aab2e75bef0aefc5b0f" => WBTC_B   # WBTC (bridged)
      },
      "optimism" => {
        "0x0b2c639c533813f4aa9d7837caf62653d097ff85" => CIRCLE,  # USDC (native)
        "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58" => TETHER,  # USDT (native)
        "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1" => MAKER_B, # DAI  (bridged)
        "0x4200000000000000000000000000000000000006" => WETH_I,  # WETH (canonical)
        "0x68f180fcce6836688e9084f035309e29bf0a2095" => WBTC_B   # WBTC (bridged)
      },
      "polygon" => {
        "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359" => CIRCLE,  # USDC (native)
        "0xc2132d05d31c914a87c6611c10748aeb04b58e8f" => TETHER,  # USDT (native)
        "0x8f3cf7ad23cd3cadbd9735aff958023239c6a063" => MAKER_B, # DAI  (bridged)
        "0x7ceb23fd6bc0add59e62ac25578270cff1b9f619" => WETH_I,  # WETH (bridged)
        "0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6" => WBTC_B,  # WBTC (bridged)
        "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270" => POLY_M   # WMATIC
      }
    }.freeze

    def self.type_tag
      "generic_erc20"
    end

    def self.matches?(contract)
      selectors = contract_selectors(contract)
      return false if selectors.empty?

      ERC20_REQUIRED_SELECTORS.all? { |s| selectors.include?(s) }
    end

    def self.contract_selectors(contract)
      return Set.new unless contract.abi.is_a?(Array)

      contract.abi
        .select { |item| item["type"] == "function" }
        .map { |fn| ChainReader::Base.selector(ChainReader::Base.function_signature(fn)) }
        .map(&:downcase)
        .to_set
    end

    def protocol_name
      "ERC-20 Token"
    end

    def panel_data
      Rails.cache.fetch(cache_key, expires_in: 60.seconds) { read_panel_data }
    end

    private

    def cache_key
      "protocol_panel:generic_erc20:v2:#{chain.slug}:#{contract.address}"
    end

    def read_panel_data
      token, admin, block_number = read_onchain_state
      return { error: "could not read token metadata" } if token[:symbol].blank? || token[:decimals].nil?

      price = fetch_price
      market_cap = compute_market_cap(token[:total_supply], token[:decimals], price)

      {
        name: token[:name],
        symbol: token[:symbol],
        decimals: token[:decimals],
        total_supply_raw: token[:total_supply],
        total_supply_formatted: format_supply(token[:total_supply], token[:decimals], token[:symbol]),
        price_usd: price,
        market_cap_usd: market_cap,
        issuer: lookup_issuer,
        admin_status: admin[:status],
        admin_roles:  admin[:roles],
        block_number: block_number,
        fetched_at: Time.current
      }
    end

    # Returns [token_metadata_hash, admin_hash, block_number] from a single
    # multicall that bundles the 4 core ERC-20 fields with any admin functions
    # present in the ABI. Admin functions not in the ABI are skipped (no probe
    # RPC cost).
    def read_onchain_state
      admin_probe_status = admin_functions_in_abi(ADMIN_STATUS_FUNCTIONS)
      admin_probe_roles  = admin_functions_in_abi(ADMIN_ROLE_FUNCTIONS)

      core_abis  = [ ERC20_NAME, ERC20_SYMBOL, ERC20_DECIMALS, ERC20_TOTAL_SUPPLY ]
      admin_abis = (admin_probe_status + admin_probe_roles).map { |spec| spec[:abi] }

      calls = (core_abis + admin_abis).map do |fn_abi|
        ChainReader::Multicall3Client::Call.new(target: contract.address, function: fn_abi)
      end
      batch = ChainReader::Multicall3Client.call(chain: chain, calls: calls)
      r = batch.results

      core_results, admin_results = r.first(4), r.drop(4)
      status_results = admin_results.first(admin_probe_status.length)
      role_results   = admin_results.drop(admin_probe_status.length)

      token = {
        name:         core_results[0].success ? core_results[0].values.first : nil,
        symbol:       core_results[1].success ? core_results[1].values.first : nil,
        decimals:     core_results[2].success ? core_results[2].values.first : nil,
        total_supply: core_results[3].success ? core_results[3].values.first : nil
      }

      admin = {
        status: admin_probe_status.zip(status_results).filter_map { |fn, res| build_admin_entry(fn, res) },
        roles:  admin_probe_roles.zip(role_results).filter_map  { |fn, res| build_admin_entry(fn, res) }
      }

      [ token, admin, batch.block_number ]
    rescue StandardError => e
      Rails.logger.warn("[GenericErc20Adapter] onchain read failed: #{e.class}: #{e.message}")
      [ { name: nil, symbol: nil, decimals: nil, total_supply: nil }, { status: [], roles: [] }, nil ]
    end

    # From the given list of admin function specs, return only those whose
    # (name, zero-inputs, matching output-type) signature exists in the
    # contract's ABI.
    def admin_functions_in_abi(specs)
      return [] unless contract.abi.is_a?(Array)

      abi_zero_arg_by_name = contract.abi.each_with_object({}) do |item, acc|
        next unless item["type"] == "function" && Array(item["inputs"]).empty?

        acc[item["name"]] = item
      end

      specs.select do |spec|
        abi_fn = abi_zero_arg_by_name[spec[:abi]["name"]]
        abi_fn &&
          Array(abi_fn["outputs"]).length == 1 &&
          abi_fn["outputs"].first["type"] == spec[:abi]["outputs"].first["type"]
      end
    end

    def build_admin_entry(spec, result)
      return nil unless result.success && !result.values.empty?

      {
        key: spec[:abi]["name"],
        label: spec[:label],
        severity: spec[:severity],
        value: result.values.first
      }
    end

    def fetch_price
      prices = DefiLlamaClient.fetch_prices(chain: chain, addresses: [ contract.address ])
      prices.dig(contract.address.downcase, "price")
    rescue DefiLlamaClient::Error => e
      Rails.logger.warn("[GenericErc20Adapter] price fetch failed: #{e.message}")
      nil
    end

    def compute_market_cap(total_supply, decimals, price)
      return nil unless total_supply && decimals && price

      (total_supply.to_f / (10.0**decimals.to_i) * price).round(2)
    end

    def format_supply(raw, decimals, symbol)
      return nil unless raw.is_a?(Integer) && decimals

      scaled = (raw.to_d / (BigDecimal(10) ** decimals.to_i)).round(2, BigDecimal::ROUND_DOWN)
      whole, frac = scaled.to_s("F").split(".")
      whole_fmt = whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
      frac_padded = (frac.to_s + "00")[0, 2]
      body = frac_padded == "00" ? whole_fmt : "#{whole_fmt}.#{frac_padded}"
      symbol.present? ? "#{body} #{symbol}" : body
    end

    def lookup_issuer
      ISSUERS.dig(chain.slug, contract.address.downcase)
    end
  end
end
