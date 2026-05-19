require "test_helper"

class GovernanceEventTest < ActiveSupport::TestCase
  setup do
    @contract = contracts(:uni_token)
  end

  test "is valid with required fields" do
    event = build_event
    assert event.valid?, event.errors.full_messages.to_sentence
  end

  test "requires contract, block_number, tx_hash, log_index, event_name, category" do
    event = GovernanceEvent.new
    refute event.valid?
    %i[contract block_number tx_hash log_index event_name category].each do |attr|
      assert event.errors[attr].any?, "expected error on #{attr}"
    end
  end

  test "rejects invalid category" do
    event = build_event(category: "spam")
    refute event.valid?
    assert event.errors[:category].any?
  end

  test "uniqueness on contract_id + tx_hash + log_index" do
    build_event.save!
    duplicate = build_event
    refute duplicate.valid?
    assert duplicate.errors[:tx_hash].any?
  end

  test "newest_first orders by block desc then log_index desc" do
    e1 = build_event(block_number: 100, log_index: 1, tx_hash: "0x" + "1" * 64).tap(&:save!)
    e2 = build_event(block_number: 200, log_index: 0, tx_hash: "0x" + "2" * 64).tap(&:save!)
    e3 = build_event(block_number: 100, log_index: 2, tx_hash: "0x" + "3" * 64).tap(&:save!)

    ordered = @contract.governance_events.newest_first.to_a
    assert_equal [ e2, e3, e1 ], ordered
  end

  test "by_category scope filters" do
    build_event(category: "role_change", tx_hash: "0x" + "a" * 64).save!
    build_event(category: "config", tx_hash: "0x" + "b" * 64).save!

    assert_equal 1, @contract.governance_events.by_category("role_change").count
  end

  test "since_block scope filters" do
    build_event(block_number: 100, tx_hash: "0x" + "a" * 64).save!
    build_event(block_number: 200, tx_hash: "0x" + "b" * 64).save!

    assert_equal 1, @contract.governance_events.since_block(150).count
  end

  test "destroying contract destroys its governance_events" do
    build_event.save!
    assert_difference -> { GovernanceEvent.count }, -1 do
      @contract.destroy
    end
  end

  private

  def build_event(**overrides)
    GovernanceEvent.new({
      contract: @contract,
      block_number: 18_234_567,
      tx_hash: "0x" + "f" * 64,
      log_index: 0,
      event_name: "OwnershipTransferred",
      category: "role_change",
      args: { "previousOwner" => "0x" + "a" * 40, "newOwner" => "0x" + "b" * 40 },
      summary: "Owner: 0xaaaa…aaaa → 0xbbbb…bbbb"
    }.merge(overrides))
  end
end
