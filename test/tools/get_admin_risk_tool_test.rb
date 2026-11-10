require "test_helper"

class GetAdminRiskToolTest < ActiveSupport::TestCase
  setup do
    @tool = GetAdminRiskTool
  end

  test "returns the admin risk profile for a verified contract" do
    contract = Contract.create!(
      chain: chains(:ethereum),
      address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      name: "FiatTokenV2_2",
      abi: [
        { "type" => "function", "name" => "paused", "inputs" => [], "outputs" => [ { "type" => "bool" } ], "stateMutability" => "view" },
        { "type" => "function", "name" => "masterMinter", "inputs" => [], "outputs" => [ { "type" => "address" } ], "stateMutability" => "view" }
      ]
    )
    profile = AdminRisk::Profiler::Result.new(
      contract: contract.address,
      chain: contract.chain.slug,
      summary: "Detected mintable and pausable controls from the verified ABI.",
      risk_flags: %w[mintable pausable],
      controls: [
        { key: "paused", label: "Paused", type: "bool", value: false, source: "view" },
        { key: "master_minter", label: "Master minter", type: "address", value: "0x" + "1" * 40, source: "view" }
      ],
      evidence: [ { type: "function", name: "pause", flag: "pausable" } ],
      warnings: [ "Upgradeability inferred from ABI/events; proxy storage resolution may be incomplete." ],
      block_number: 25_000_123,
      fetched_at: Time.utc(2026, 5, 24, 18, 30, 0),
      error: nil
    )

    stub_class_method(AdminRisk::Profiler, :call, ->(**_) { profile }) do
      result = @tool.payload(chain: "eth", address: contract.address)

      assert_equal contract.address, result[:address]
      refute result.key?(:error), "no error: nil on success"
      assert_equal "eth", result[:chain]
      assert_equal ContractSlugResolver.for(contract.chain.slug, contract.address), result[:slug]
      assert_equal profile.summary, result[:summary]
      assert_equal profile.risk_flags, result[:risk_flags]
      assert_equal profile.controls, result[:controls]
      refute result.key?(:recent_governance)
      assert_equal profile.evidence, result[:evidence]
      assert_equal profile.warnings, result[:warnings]
      assert_equal profile.block_number, result[:block_number]
      assert_equal "2026-05-24T18:30:00Z", result[:fetched_at]
      assert_nil result[:error]
    end
  end

  test "accepts slug instead of chain+address" do
    contract = Contract.create!(
      chain: chains(:ethereum),
      address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      name: "FiatTokenV2_2",
      abi: []
    )
    profile = AdminRisk::Profiler::Result.new(
      contract: contract.address,
      chain: contract.chain.slug,
      summary: "No admin risk controls detected from the verified ABI.",
      risk_flags: [],
      controls: [],
      evidence: [],
      warnings: [],
      block_number: nil,
      fetched_at: Time.utc(2026, 5, 24, 18, 30, 0),
      error: nil
    )

    stub_class_method(AdminRisk::Profiler, :call, ->(**_) { profile }) do
      result = @tool.payload(slug: "usdc-eth")
      assert_equal "eth", result[:chain]
      assert_equal contract.address, result[:address]
    end
  end

  test "surfaces profiler errors without raising" do
    contract = contracts(:empty_contract)
    profile = AdminRisk::Profiler::Result.new(
      contract: contract.address,
      chain: contract.chain.slug,
      summary: "Could not build admin risk profile.",
      risk_flags: [],
      controls: [],
      evidence: [],
      warnings: [],
      block_number: nil,
      fetched_at: Time.utc(2026, 5, 24, 18, 30, 0),
      error: "profiler boom"
    )

    stub_class_method(AdminRisk::Profiler, :call, ->(**_) { profile }) do
      result = @tool.payload(chain: "eth", address: contract.address)
      assert_equal "profiler boom", result[:error]
      assert_equal "Could not build admin risk profile.", result[:summary]
    end
  end
end
