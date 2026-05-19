require "test_helper"

class AdminRisk::ProfilerTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  def usdc_like_abi
    functions = [
      [ "paused", [], "bool", "view" ],
      [ "owner", [], "address", "view" ],
      [ "masterMinter", [], "address", "view" ],
      [ "pauser", [], "address", "view" ],
      [ "blacklister", [], "address", "view" ],
      [ "rescuer", [], "address", "view" ],
      [ "configureMinter", [ "address", "uint256" ], "bool", "nonpayable" ],
      [ "mint", [ "address", "uint256" ], "bool", "nonpayable" ],
      [ "pause", [], nil, "nonpayable" ],
      [ "unpause", [], nil, "nonpayable" ],
      [ "blacklist", [ "address" ], nil, "nonpayable" ],
      [ "unBlacklist", [ "address" ], nil, "nonpayable" ]
    ].map do |name, inputs, output, mutability|
      {
        "type" => "function",
        "name" => name,
        "inputs" => inputs.map { |type| { "type" => type } },
        "outputs" => output ? [ { "type" => output } ] : [],
        "stateMutability" => mutability
      }
    end

    events = %w[MinterConfigured Blacklisted UnBlacklisted PauserChanged BlacklisterChanged].map do |name|
      { "type" => "event", "name" => name, "inputs" => [] }
    end

    functions + events
  end

  test "detects stablecoin admin capabilities and reads current controls" do
    contract = Contract.create!(
      chain: chains(:ethereum),
      address: "0x" + "a" * 40,
      name: "FiatTokenV2_2",
      abi: usdc_like_abi
    )
    GovernanceEvent.create!(
      contract: contract,
      block_number: 123,
      tx_hash: "0x" + "1" * 64,
      log_index: 0,
      event_name: "BlacklisterChanged",
      category: "role_change",
      args: {},
      summary: "Blacklister updated"
    )

    results = [
      ChainReader::Multicall3Client::Result.new(success: true, values: [ false ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x1111111111111111111111111111111111111111" ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x2222222222222222222222222222222222222222" ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x3333333333333333333333333333333333333333" ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x4444444444444444444444444444444444444444" ]),
      ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x0000000000000000000000000000000000000000" ])
    ]

    stub_class_method(ChainReader::Multicall3Client, :call,
      ->(**_) { batch_of(results, block_number: 24_000_000) }) do
      profile = AdminRisk::Profiler.call(contract: contract)

      assert profile.success?
      assert_includes profile.risk_flags, "mintable"
      assert_includes profile.risk_flags, "pausable"
      assert_includes profile.risk_flags, "blacklistable"
      assert_equal 24_000_000, profile.block_number
      assert_equal %w[paused owner master_minter pauser blacklister rescuer], profile.controls.map { |c| c[:key] }
      assert_equal 1, profile.recent_governance[:count]
      assert_equal "BlacklisterChanged", profile.recent_governance[:latest_event]
      assert_match(/mintable/, profile.summary)
    end
  end

  test "returns neutral profile when no privileged controls are detected" do
    contract = contracts(:empty_contract)
    contract.update!(abi: [ { "type" => "function", "name" => "name", "inputs" => [], "outputs" => [ { "type" => "string" } ], "stateMutability" => "view" } ])

    profile = AdminRisk::Profiler.call(contract: contract)

    assert profile.success?
    assert_empty profile.risk_flags
    assert_empty profile.controls
    assert_equal "No admin risk controls detected from the verified ABI.", profile.summary
  end

  test "uses implementation address as upgradeability evidence when present" do
    contract = contracts(:empty_contract)
    contract.update!(abi: [], implementation_address: "0x" + "b" * 40)

    profile = AdminRisk::Profiler.call(contract: contract)

    assert_includes profile.risk_flags, "upgradeable"
    assert_equal "implementation", profile.controls.first[:key]
    assert_equal "proxy", profile.controls.first[:source]
  end

  test "emits warning when upgradeable is inferred from ABI but no implementation control read" do
    # ABI advertises an upgradeTo() write function but provides no zero-arg
    # implementation() view and no EIP-1967 implementation_address. The
    # profile should still flag the contract as upgradeable, AND emit a
    # warning that the proxy storage couldn't be resolved — so a downstream
    # reader doesn't mistake an empty controls list for "no proxy here."
    contract = Contract.create!(
      chain: chains(:ethereum),
      address: "0x" + "c" * 40,
      name: "PretendUpgradeable",
      abi: [
        { "type" => "function", "name" => "upgradeTo",
          "inputs" => [ { "type" => "address" } ], "outputs" => [],
          "stateMutability" => "nonpayable" }
      ]
    )

    profile = AdminRisk::Profiler.call(contract: contract)

    assert profile.success?
    assert_includes profile.risk_flags, "upgradeable"
    assert_empty profile.controls
    assert profile.warnings.any? { |w| w.include?("Upgradeability inferred") },
           "expected the 'inferred upgradeability' warning, got: #{profile.warnings.inspect}"
  end

  test "tolerates Multicall3 failure and still returns a successful profile with ABI-derived flags" do
    # Even if the on-chain control read crashes (RPC down, batch malformed),
    # the ABI-derived risk_flags must still surface so the page is useful
    # offline. controls=[] and block_number=nil tell the caller the live
    # read failed without poisoning the whole render.
    contract = Contract.create!(
      chain: chains(:ethereum),
      address: "0x" + "d" * 40,
      name: "PartialReadable",
      abi: usdc_like_abi
    )

    stub_class_method(ChainReader::Multicall3Client, :call,
      ->(**_) { raise StandardError, "multicall down" }) do
      profile = AdminRisk::Profiler.call(contract: contract)

      assert profile.success?, "Multicall3 failure must not propagate to caller"
      assert_includes profile.risk_flags, "mintable"
      assert_includes profile.risk_flags, "pausable"
      assert_empty profile.controls
      assert_nil profile.block_number
    end
  end

  test "returns error Result when capability detection raises unexpectedly" do
    # Top-level rescue safety net: any unexpected crash inside the profiler
    # surfaces as Result#error rather than bringing down the contract page.
    contract = contracts(:uni_token)
    contract.define_singleton_method(:events) { raise StandardError, "events crashed" }

    profile = AdminRisk::Profiler.call(contract: contract)

    refute profile.success?
    assert_equal "events crashed", profile.error
    assert_equal "Could not build admin risk profile.", profile.summary
    assert_empty profile.risk_flags
  end
end
