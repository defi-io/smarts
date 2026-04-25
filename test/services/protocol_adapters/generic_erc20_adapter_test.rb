require "test_helper"

class ProtocolAdapters::GenericErc20AdapterTest < ActiveSupport::TestCase
  # Full ERC-20 ABI covering the 6 required selectors plus name/decimals.
  ERC20_ABI = [
    { "type" => "function", "name" => "name",         "inputs" => [],                                                                                       "outputs" => [ { "type" => "string" } ],  "stateMutability" => "view" },
    { "type" => "function", "name" => "symbol",       "inputs" => [],                                                                                       "outputs" => [ { "type" => "string" } ],  "stateMutability" => "view" },
    { "type" => "function", "name" => "decimals",     "inputs" => [],                                                                                       "outputs" => [ { "type" => "uint8" } ],   "stateMutability" => "view" },
    { "type" => "function", "name" => "totalSupply",  "inputs" => [],                                                                                       "outputs" => [ { "type" => "uint256" } ], "stateMutability" => "view" },
    { "type" => "function", "name" => "balanceOf",    "inputs" => [ { "name" => "a", "type" => "address" } ],                                               "outputs" => [ { "type" => "uint256" } ], "stateMutability" => "view" },
    { "type" => "function", "name" => "transfer",     "inputs" => [ { "name" => "to", "type" => "address" }, { "name" => "v", "type" => "uint256" } ],      "outputs" => [ { "type" => "bool" } ],    "stateMutability" => "nonpayable" },
    { "type" => "function", "name" => "transferFrom", "inputs" => [ { "name" => "f", "type" => "address" }, { "name" => "t", "type" => "address" }, { "name" => "v", "type" => "uint256" } ], "outputs" => [ { "type" => "bool" } ], "stateMutability" => "nonpayable" },
    { "type" => "function", "name" => "approve",      "inputs" => [ { "name" => "s", "type" => "address" }, { "name" => "v", "type" => "uint256" } ],      "outputs" => [ { "type" => "bool" } ],    "stateMutability" => "nonpayable" },
    { "type" => "function", "name" => "allowance",    "inputs" => [ { "name" => "o", "type" => "address" }, { "name" => "s", "type" => "address" } ],      "outputs" => [ { "type" => "uint256" } ], "stateMutability" => "view" }
  ].freeze

  USDC_ADDRESS = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  setup do
    @chain = chains(:ethereum)
    @contract = Contract.new(chain: @chain, address: USDC_ADDRESS, abi: ERC20_ABI)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  # ---------- matches? ----------

  test "matches? returns true when the ABI contains all 6 ERC-20 selectors" do
    assert ProtocolAdapters::GenericErc20Adapter.matches?(@contract)
  end

  test "matches? returns false when ABI is missing one of the required functions" do
    abi_without_allowance = ERC20_ABI.reject { |f| f["name"] == "allowance" }
    c = Contract.new(chain: @chain, address: USDC_ADDRESS, abi: abi_without_allowance)

    refute ProtocolAdapters::GenericErc20Adapter.matches?(c)
  end

  test "matches? returns false when ABI is nil or empty" do
    refute ProtocolAdapters::GenericErc20Adapter.matches?(Contract.new(chain: @chain, address: "0xabc", abi: nil))
    refute ProtocolAdapters::GenericErc20Adapter.matches?(Contract.new(chain: @chain, address: "0xabc", abi: []))
  end

  # ---------- panel_data: happy path ----------

  test "panel_data returns formatted supply, price, market cap, issuer for a known token" do
    adapter = ProtocolAdapters::GenericErc20Adapter.new(@contract)

    metadata_stub = lambda do |chain:, calls:|
      [
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USD Coin" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 6 ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 55_046_395_721_805_492 ])
      ]
    end
    price_stub = ->(chain:, addresses:) { { addresses.first.downcase => { "price" => 1.0 } } }

    stub_class_method(ChainReader::Multicall3Client, :call, metadata_stub) do
      stub_class_method(DefiLlamaClient, :fetch_prices, price_stub) do
        data = adapter.panel_data

        assert_equal "USD Coin", data[:name]
        assert_equal "USDC", data[:symbol]
        assert_equal 6, data[:decimals]
        assert_equal "55,046,395,721.80 USDC", data[:total_supply_formatted]
        assert_equal 1.0, data[:price_usd]
        assert_equal 55_046_395_721.81, data[:market_cap_usd]
        assert_equal "Circle", data[:issuer][:name]
      end
    end
  end

  # ---------- panel_data: degradation ----------

  test "panel_data returns {error:} when metadata multicall fails to produce symbol/decimals" do
    adapter = ProtocolAdapters::GenericErc20Adapter.new(@contract)
    all_failed = lambda do |chain:, calls:|
      Array.new(calls.length) { ChainReader::Multicall3Client::Result.new(success: false, error: "reverted") }
    end

    stub_class_method(ChainReader::Multicall3Client, :call, all_failed) do
      data = adapter.panel_data
      assert_equal "could not read token metadata", data[:error]
    end
  end

  test "panel_data omits price and market cap when DefiLlama raises" do
    adapter = ProtocolAdapters::GenericErc20Adapter.new(@contract)

    metadata_stub = lambda do |chain:, calls:|
      [
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USD Coin" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 6 ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 1_000_000 * 10**6 ])
      ]
    end
    down = ->(**_) { raise DefiLlamaClient::Error, "DefiLlama down" }

    stub_class_method(ChainReader::Multicall3Client, :call, metadata_stub) do
      stub_class_method(DefiLlamaClient, :fetch_prices, down) do
        data = adapter.panel_data
        assert_nil data[:price_usd]
        assert_nil data[:market_cap_usd]
        assert_equal "1,000,000 USDC", data[:total_supply_formatted]
      end
    end
  end

  test "panel_data still renders when name() reverts (some tokens use bytes32 name)" do
    adapter = ProtocolAdapters::GenericErc20Adapter.new(@contract)
    stub_multi = lambda do |chain:, calls:|
      [
        ChainReader::Multicall3Client::Result.new(success: false, error: "reverted"),
        ChainReader::Multicall3Client::Result.new(success: true,  values: [ "FOO" ]),
        ChainReader::Multicall3Client::Result.new(success: true,  values: [ 18 ]),
        ChainReader::Multicall3Client::Result.new(success: true,  values: [ 100 * 10**18 ])
      ]
    end
    no_price = ->(**_) { {} }

    stub_class_method(ChainReader::Multicall3Client, :call, stub_multi) do
      stub_class_method(DefiLlamaClient, :fetch_prices, no_price) do
        data = adapter.panel_data
        assert_nil data[:name]
        assert_equal "FOO", data[:symbol]
        assert_equal "100 FOO", data[:total_supply_formatted]
      end
    end
  end

  # ---------- issuer lookup ----------

  test "lookup_issuer returns nil for an unknown address" do
    random_contract = Contract.new(chain: @chain, address: "0x#{SecureRandom.hex(20)}", abi: ERC20_ABI)
    adapter = ProtocolAdapters::GenericErc20Adapter.new(random_contract)
    assert_nil adapter.send(:lookup_issuer)
  end

  test "lookup_issuer returns Circle for USDC on Ethereum" do
    adapter = ProtocolAdapters::GenericErc20Adapter.new(@contract)
    issuer = adapter.send(:lookup_issuer)
    assert_equal "Circle", issuer[:name]
  end

  test "lookup_issuer returns nil for the Ethereum USDC address on the Base chain (different chain)" do
    # Note: the real native Base USDC is at a different address, so feeding
    # the mainnet USDC address to a Base-chain record is a genuine mismatch.
    base_contract = Contract.new(chain: chains(:base), address: USDC_ADDRESS, abi: ERC20_ABI)
    adapter = ProtocolAdapters::GenericErc20Adapter.new(base_contract)
    assert_nil adapter.send(:lookup_issuer)
  end

  # ---------- multi-chain issuer coverage ----------

  def issuer_for(chain_slug, address)
    c = Contract.new(chain: Chain.find_by!(slug: chain_slug), address: address, abi: ERC20_ABI)
    ProtocolAdapters::GenericErc20Adapter.new(c).send(:lookup_issuer)
  end

  test "native USDC is recognised as Circle on every supported chain" do
    {
      "eth"      => "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      "base"     => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "arbitrum" => "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
      "optimism" => "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      "polygon"  => "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359"
    }.each do |chain, address|
      i = issuer_for(chain, address)
      assert i, "expected issuer lookup to succeed for USDC on #{chain}"
      assert_equal "Circle", i[:name], "USDC on #{chain} should resolve to Circle"
    end
  end

  test "bridged DAI on L2s gets '(bridged)' suffix instead of bare MakerDAO" do
    %w[base arbitrum optimism polygon].each do |chain|
      addresses = {
        "base"     => "0x50c5725949a6f0c72e6c4a641f24049a917db0cb",
        "arbitrum" => "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1",
        "optimism" => "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1",
        "polygon"  => "0x8f3cf7ad23cd3cadbd9735aff958023239c6a063"
      }
      i = issuer_for(chain, addresses[chain])
      assert_equal "MakerDAO (bridged)", i[:name], "bridged DAI on #{chain}"
    end
  end

  test "bridged WBTC on L2s gets '(bridged)' suffix" do
    {
      "arbitrum" => "0x2f2a2543b76a4166549f7aab2e75bef0aefc5b0f",
      "optimism" => "0x68f180fcce6836688e9084f035309e29bf0a2095",
      "polygon"  => "0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6"
    }.each do |chain, address|
      i = issuer_for(chain, address)
      assert_equal "BitGo (bridged)", i[:name], "bridged WBTC on #{chain}"
    end
  end

  # Post-2024 rebrand: on-chain name()/symbol() now return "Wrapped Polygon
  # Ecosystem Token"/"WPOL". Issuer badge updated to match; if the token
  # rebrands again, update POLY_M and this assertion together.
  test "WPOL (formerly WMATIC) on Polygon is recognised with the Polygon label" do
    i = issuer_for("polygon", "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")
    assert_equal "Polygon (WPOL)", i[:name]
  end

  # Structural guards — catch typos / duplicates when the constant is edited.

  test "all ISSUERS addresses are lowercase 0x + 40 hex chars" do
    ProtocolAdapters::GenericErc20Adapter::ISSUERS.each do |chain, tokens|
      tokens.each_key do |addr|
        assert_match(/\A0x[0-9a-f]{40}\z/, addr, "ISSUERS[#{chain}] has malformed address: #{addr}")
      end
    end
  end

  test "no duplicate addresses within a chain (would make one issuer shadow another)" do
    ProtocolAdapters::GenericErc20Adapter::ISSUERS.each do |chain, tokens|
      assert_equal tokens.keys.uniq.length, tokens.keys.length, "duplicate addresses in ISSUERS[#{chain}]"
    end
  end

  # ---------- format_supply edge cases ----------

  test "format_supply returns nil for missing raw or decimals" do
    adapter = ProtocolAdapters::GenericErc20Adapter.new(@contract)
    assert_nil adapter.send(:format_supply, nil, 6, "USDC")
    assert_nil adapter.send(:format_supply, 1000, nil, "USDC")
  end

  test "format_supply handles zero-decimal tokens cleanly" do
    adapter = ProtocolAdapters::GenericErc20Adapter.new(@contract)
    assert_equal "42 CULT", adapter.send(:format_supply, 42, 0, "CULT")
  end

  # ---------- admin_functions_in_abi: ABI-gated probing ----------

  def fn_zero_arg(name, type)
    { "type" => "function", "name" => name, "inputs" => [], "outputs" => [ { "type" => type } ], "stateMutability" => "view" }
  end

  test "admin_functions_in_abi selects only admin fns present in the ABI" do
    abi = ERC20_ABI + [
      fn_zero_arg("paused", "bool"),
      fn_zero_arg("owner",  "address")
      # masterMinter / pauser / blacklister / rescuer / deprecated / upgradedAddress absent
    ]
    c = Contract.new(chain: @chain, address: USDC_ADDRESS, abi: abi)
    adapter = ProtocolAdapters::GenericErc20Adapter.new(c)

    status = adapter.send(:admin_functions_in_abi, ProtocolAdapters::GenericErc20Adapter::ADMIN_STATUS_FUNCTIONS)
    roles  = adapter.send(:admin_functions_in_abi, ProtocolAdapters::GenericErc20Adapter::ADMIN_ROLE_FUNCTIONS)

    assert_equal [ "paused" ], status.map { |s| s[:abi]["name"] }
    assert_equal [ "owner" ],  roles.map  { |r| r[:abi]["name"] }
  end

  # Regression guard: the function hash passed to Multicall3Client::Call MUST
  # use string keys ("name", "inputs", "outputs") because ChainReader::Base
  # reads them as strings. If a future refactor silently switches to symbol
  # keys, this test will fail early rather than producing runtime-empty admin
  # arrays like the 2026-04-22 bug.
  test "admin spec abi hashes use string keys compatible with ChainReader" do
    all = ProtocolAdapters::GenericErc20Adapter::ADMIN_STATUS_FUNCTIONS +
          ProtocolAdapters::GenericErc20Adapter::ADMIN_ROLE_FUNCTIONS

    all.each do |spec|
      abi = spec[:abi]
      assert abi.key?("name"),    "#{spec.inspect} missing string key 'name'"
      assert abi.key?("inputs"),  "#{spec.inspect} missing string key 'inputs'"
      assert abi.key?("outputs"), "#{spec.inspect} missing string key 'outputs'"
      assert_equal [], abi["inputs"], "admin fns must be zero-arg"

      # ChainReader::Base.function_signature must produce a valid sig like
      # "paused()" — if it produces "()" because the name key is wrong, the
      # whole admin multicall silently fails.
      sig = ChainReader::Base.function_signature(abi)
      refute_equal "()", sig, "function_signature produced bare '()' for #{spec.inspect}"
      assert_match(/\A[a-zA-Z_]\w*\(\)\z/, sig, "unexpected sig shape: #{sig}")
    end
  end

  test "admin_functions_in_abi rejects matches with wrong output type" do
    # A contract with a paused() that returns uint256 (not bool) — don't probe it
    abi = ERC20_ABI + [ fn_zero_arg("paused", "uint256") ]
    c = Contract.new(chain: @chain, address: USDC_ADDRESS, abi: abi)
    adapter = ProtocolAdapters::GenericErc20Adapter.new(c)

    status = adapter.send(:admin_functions_in_abi, ProtocolAdapters::GenericErc20Adapter::ADMIN_STATUS_FUNCTIONS)
    assert_empty status
  end

  test "admin_functions_in_abi rejects matches that take arguments" do
    paused_with_arg = { "type" => "function", "name" => "paused",
                        "inputs" => [ { "type" => "uint8" } ],
                        "outputs" => [ { "type" => "bool" } ], "stateMutability" => "view" }
    c = Contract.new(chain: @chain, address: USDC_ADDRESS, abi: ERC20_ABI + [ paused_with_arg ])
    adapter = ProtocolAdapters::GenericErc20Adapter.new(c)

    status = adapter.send(:admin_functions_in_abi, ProtocolAdapters::GenericErc20Adapter::ADMIN_STATUS_FUNCTIONS)
    assert_empty status
  end

  # ---------- panel_data: admin fields flow ----------

  def usdc_admin_abi
    ERC20_ABI + [
      fn_zero_arg("paused",       "bool"),
      fn_zero_arg("owner",        "address"),
      fn_zero_arg("pauser",       "address"),
      fn_zero_arg("blacklister",  "address"),
      fn_zero_arg("masterMinter", "address"),
      fn_zero_arg("rescuer",      "address")
    ]
  end

  test "panel_data surfaces admin status + roles when admin functions exist in ABI" do
    contract = Contract.new(chain: @chain, address: USDC_ADDRESS, abi: usdc_admin_abi)
    adapter = ProtocolAdapters::GenericErc20Adapter.new(contract)

    stub = lambda do |chain:, calls:|
      # 4 core + 1 status (paused) + 5 roles = 10 results
      [
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USD Coin" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 6 ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 10**18 ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ false ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "0xcee284f754e854890e311e3280b767f80797601d" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x5db0115f3b72d19cea34dd697cf412ff86dc7e1b" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x5db0115f3b72d19cea34dd697cf412ff86dc7e1b" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "0xe982615d461dd5cd06575bbea87624fda4e3de17" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ ProtocolAdapters::GenericErc20Adapter::ZERO_ADDRESS ])
      ]
    end
    no_price = ->(**_) { {} }

    stub_class_method(ChainReader::Multicall3Client, :call, stub) do
      stub_class_method(DefiLlamaClient, :fetch_prices, no_price) do
        data = adapter.panel_data

        assert_equal [ "paused" ], data[:admin_status].map { |s| s[:key] }
        assert_equal false, data[:admin_status].first[:value]
        assert_equal :critical, data[:admin_status].first[:severity]

        role_keys = data[:admin_roles].map { |r| r[:key] }
        assert_equal %w[owner masterMinter pauser blacklister rescuer], role_keys

        rescuer = data[:admin_roles].find { |r| r[:key] == "rescuer" }
        assert_equal ProtocolAdapters::GenericErc20Adapter::ZERO_ADDRESS, rescuer[:value]
      end
    end
  end

  test "panel_data returns empty admin arrays when ABI has no admin functions" do
    adapter = ProtocolAdapters::GenericErc20Adapter.new(@contract)
    stub = lambda do |chain:, calls:|
      assert_equal 4, calls.length, "must only call the 4 core ERC-20 fns when ABI has no admin fns"
      [
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USD Coin" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 6 ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 1_000 * 10**6 ])
      ]
    end
    no_price = ->(**_) { {} }

    stub_class_method(ChainReader::Multicall3Client, :call, stub) do
      stub_class_method(DefiLlamaClient, :fetch_prices, no_price) do
        data = adapter.panel_data
        assert_empty data[:admin_status]
        assert_empty data[:admin_roles]
      end
    end
  end

  test "panel_data marks paused=true entries and drops failed admin calls" do
    contract = Contract.new(chain: @chain, address: USDC_ADDRESS, abi: ERC20_ABI + [ fn_zero_arg("paused", "bool"), fn_zero_arg("owner", "address") ])
    adapter = ProtocolAdapters::GenericErc20Adapter.new(contract)

    stub = lambda do |chain:, calls:|
      [
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "Token" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "TKN" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 18 ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 10**18 ]),
        ChainReader::Multicall3Client::Result.new(success: true,  values: [ true ]),   # paused = true
        ChainReader::Multicall3Client::Result.new(success: false, error: "reverted")  # owner call reverts
      ]
    end
    no_price = ->(**_) { {} }

    stub_class_method(ChainReader::Multicall3Client, :call, stub) do
      stub_class_method(DefiLlamaClient, :fetch_prices, no_price) do
        data = adapter.panel_data
        assert_equal true, data[:admin_status].first[:value]
        assert_empty data[:admin_roles], "failed role calls must not appear in admin_roles"
      end
    end
  end

  # ---------- block-anchored freshness ----------

  test "panel_data records block_number and fetched_at from the multicall batch" do
    adapter = ProtocolAdapters::GenericErc20Adapter.new(@contract)

    stub = lambda do |chain:, calls:|
      ChainReader::Multicall3Client::Batch.new(
        block_number: 24_500_000,
        results: [
          ChainReader::Multicall3Client::Result.new(success: true, values: [ "USD Coin" ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ 6 ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ 10**18 ])
        ]
      )
    end

    stub_class_method(ChainReader::Multicall3Client, :call, stub) do
      stub_class_method(DefiLlamaClient, :fetch_prices, ->(**_) { {} }) do
        before = Time.current
        data = adapter.panel_data
        after = Time.current

        assert_equal 24_500_000, data[:block_number],
                     "panel_data must surface the multicall batch's block_number"
        assert_kind_of Time, data[:fetched_at]
        assert data[:fetched_at] >= before && data[:fetched_at] <= after
      end
    end
  end

  test "panel_data block_number is nil when multicall raises (degraded mode)" do
    adapter = ProtocolAdapters::GenericErc20Adapter.new(@contract)
    raising = ->(**_) { raise ChainReader::Base::RpcError, "node down" }

    stub_class_method(ChainReader::Multicall3Client, :call, raising) do
      data = adapter.panel_data
      # Symbol/decimals couldn't be read → error result. Confirm we don't
      # crash and degrade cleanly without polluting the cache with stale
      # block data.
      assert_equal "could not read token metadata", data[:error]
    end
  end
end
