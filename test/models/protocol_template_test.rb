require "test_helper"

class ProtocolTemplateTest < ActiveSupport::TestCase
  test "validates presence of core attributes" do
    tmpl = ProtocolTemplate.new
    assert_not tmpl.valid?
    assert_includes tmpl.errors[:protocol_key], "can't be blank"
    assert_includes tmpl.errors[:display_name], "can't be blank"
    assert_includes tmpl.errors[:match_type], "can't be blank"
    assert_includes tmpl.errors[:required_selectors], "can't be blank"
  end

  test "validates required_selectors is not empty" do
    tmpl = ProtocolTemplate.new(
      protocol_key: "x", display_name: "X",
      match_type: "required_selectors", required_selectors: []
    )
    assert_not tmpl.valid?
    assert_includes tmpl.errors[:required_selectors], "can't be blank"
  end

  test "protocol_key is unique" do
    dup = ProtocolTemplate.new(
      protocol_key: protocol_templates(:erc20).protocol_key,
      display_name: "Duplicate",
      match_type: "required_selectors",
      required_selectors: [ "0x18160ddd" ]
    )
    assert_not dup.valid?
    assert_includes dup.errors[:protocol_key], "has already been taken"
  end

  test "match_type must be a known kind" do
    tmpl = ProtocolTemplate.new(
      protocol_key: "foo", display_name: "Foo",
      match_type: "bogus", required_selectors: [ "0xabcd" ]
    )
    assert_not tmpl.valid?
    assert_includes tmpl.errors[:match_type], "is not included in the list"
  end

  test "by_priority orders ascending (more specific first)" do
    # Fixtures: uniswap_v3_pool priority 10, erc20 priority 100.
    ordered = ProtocolTemplate.by_priority.pluck(:protocol_key)
    assert_equal "uniswap_v3_pool", ordered.first
    assert_equal "erc20",           ordered.last
  end

  test "required_selectors_set is case-insensitive via downcase" do
    tmpl = ProtocolTemplate.new(required_selectors: [ "0xABCDEF12", "0xdeadBEEF" ])
    assert_includes tmpl.required_selectors_set, "0xabcdef12"
    assert_includes tmpl.required_selectors_set, "0xdeadbeef"
  end
end
