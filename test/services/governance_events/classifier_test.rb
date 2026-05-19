require "test_helper"

class GovernanceEvents::ClassifierTest < ActiveSupport::TestCase
  test "categorizes USDC FiatTokenV2_2 events correctly" do
    expectations = {
      "OwnershipTransferred"   => "role_change",
      "MasterMinterChanged"    => "config",
      "PauserChanged"          => "config",
      "BlacklisterChanged"     => "config",
      "RescuerChanged"         => "config",
      "MinterConfigured"       => "config",
      "MinterRemoved"          => "config",
      "Pause"                  => "lifecycle",
      "Unpause"                => "lifecycle",
      "Blacklisted"            => "risk_action",
      "UnBlacklisted"          => "risk_action"
    }

    expectations.each do |name, expected_category|
      event = { "name" => name, "type" => "event" }
      assert_equal expected_category, GovernanceEvents::Classifier.category_for(event),
                   "expected #{name} to be #{expected_category}"
    end
  end

  test "ignores non-governance events" do
    %w[Transfer Approval Swap Mint Burn AuthorizationUsed AuthorizationCanceled].each do |name|
      event = { "name" => name, "type" => "event" }
      assert_nil GovernanceEvents::Classifier.category_for(event),
                 "expected #{name} to be nil (non-governance)"
      refute GovernanceEvents::Classifier.governance?(event)
    end
  end

  test "categorizes proxy upgrade events" do
    assert_equal "upgrade", GovernanceEvents::Classifier.category_for({ "name" => "Upgraded" })
    assert_equal "upgrade", GovernanceEvents::Classifier.category_for({ "name" => "AdminChanged" })
  end

  test "categorizes Aave-style events via suffix heuristic" do
    matches = {
      "OwnershipTransferred"      => "role_change",
      "BridgeProtocolFeeChanged"  => "config",
      "AdminChanged"              => "upgrade"
    }
    matches.each do |name, expected|
      assert_equal expected, GovernanceEvents::Classifier.category_for({ "name" => name })
    end

    %w[ReserveActiveSet ReserveBorrowing FeeAmountEnabled
       BridgeProtocolFeeUpdated FlashLoanPremiumUpdated
       ReserveInitialized PriceOracleUpdated].each do |name|
      assert_nil GovernanceEvents::Classifier.category_for({ "name" => name }),
                 "expected #{name} to be nil"
    end
  end

  test "handles malformed event abi gracefully" do
    assert_nil GovernanceEvents::Classifier.category_for(nil)
    assert_nil GovernanceEvents::Classifier.category_for({})
    assert_nil GovernanceEvents::Classifier.category_for({ "name" => nil })
    assert_nil GovernanceEvents::Classifier.category_for({ "name" => 123 })
  end

  test "filter returns only governance events" do
    abi = [
      { "name" => "Transfer", "type" => "event" },
      { "name" => "OwnershipTransferred", "type" => "event" },
      { "name" => "Approval", "type" => "event" },
      { "name" => "Pause", "type" => "event" }
    ]

    filtered = GovernanceEvents::Classifier.filter(abi)
    assert_equal %w[OwnershipTransferred Pause], filtered.map { |e| e["name"] }
  end

  test "classify returns name + category + abi for each governance event" do
    abi = [
      { "name" => "Transfer", "type" => "event" },
      { "name" => "OwnershipTransferred", "type" => "event" }
    ]

    result = GovernanceEvents::Classifier.classify(abi)
    assert_equal 1, result.length
    assert_equal "OwnershipTransferred", result.first[:name]
    assert_equal "role_change", result.first[:category]
    assert_equal "event", result.first[:abi]["type"]
  end

  test "summarize OwnershipTransferred" do
    summary = GovernanceEvents::Classifier.summarize("OwnershipTransferred", {
      "previousOwner" => "0x" + "a" * 40,
      "newOwner"      => "0x" + "b" * 40
    })
    assert_equal "Owner: 0xaaaa…aaaa → 0xbbbb…bbbb", summary
  end

  test "summarize MinterConfigured" do
    summary = GovernanceEvents::Classifier.summarize("MinterConfigured", {
      "minter" => "0x" + "c" * 40,
      "minterAllowedAmount" => 5_000_000_000_000
    })
    assert_equal "Minter 0xcccc…cccc allowance set to 5,000,000,000,000", summary
  end

  test "summarize MasterMinterChanged" do
    summary = GovernanceEvents::Classifier.summarize("MasterMinterChanged", {
      "newMasterMinter" => "0x" + "e" * 40
    })
    assert_equal "Master minter updated to 0xeeee…eeee", summary
  end

  test "summarize Blacklisted picks _account or account" do
    s1 = GovernanceEvents::Classifier.summarize("Blacklisted", { "_account" => "0x" + "1" * 40 })
    s2 = GovernanceEvents::Classifier.summarize("Blacklisted", { "account"  => "0x" + "2" * 40 })
    s3 = GovernanceEvents::Classifier.summarize("UnBlacklisted", { "_account" => "0x" + "3" * 40 })

    assert_equal "0x1111…1111 added to blacklist", s1
    assert_equal "0x2222…2222 added to blacklist", s2
    assert_equal "0x3333…3333 removed from blacklist", s3
  end

  test "summarize Pause and Unpause" do
    assert_equal "Contract paused",  GovernanceEvents::Classifier.summarize("Pause", {})
    assert_equal "Contract unpaused", GovernanceEvents::Classifier.summarize("Unpause", {})
  end

  test "summarize Upgraded" do
    summary = GovernanceEvents::Classifier.summarize("Upgraded", {
      "implementation" => "0x" + "9" * 40
    })
    assert_equal "Implementation upgraded to 0x9999…9999", summary
  end

  test "summarize AdminChanged" do
    summary = GovernanceEvents::Classifier.summarize("AdminChanged", {
      "previousAdmin" => "0x" + "a" * 40,
      "newAdmin"      => "0x" + "b" * 40
    })
    assert_equal "Proxy admin: 0xaaaa…aaaa → 0xbbbb…bbbb", summary
  end

  test "summarize falls back to generic format for unknown events" do
    summary = GovernanceEvents::Classifier.summarize("BridgeProtocolFeeChanged", {
      "newFee" => 250,
      "updater" => "0x" + "f" * 40
    })
    assert_equal "BridgeProtocolFeeChanged(newFee=250, updater=0xffff…ffff)", summary
  end

  test "summarize handles nil args" do
    assert_equal "Owner: — → —", GovernanceEvents::Classifier.summarize("OwnershipTransferred", nil)
  end

  test "summarize handles non-address string values without mangling" do
    summary = GovernanceEvents::Classifier.summarize("UnknownEvent", {
      "label" => "hello",
      "count" => 42
    })
    assert_equal "UnknownEvent(label=hello, count=42)", summary
  end
end
