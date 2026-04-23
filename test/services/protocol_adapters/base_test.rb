require "test_helper"

class ProtocolAdapters::BaseTest < ActiveSupport::TestCase
  setup do
    @chain = chains(:ethereum)
    @contract = contracts(:uni_token)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "resolve returns an adapter instance when one matches" do
    fake_adapter = make_fake_adapter(tag: "fake_a", matches: true)

    with_adapter_list([ fake_adapter ]) do
      result = ProtocolAdapters::Base.resolve(@contract)
      assert_instance_of fake_adapter, result
    end
  end

  test "resolve returns nil when no adapter matches" do
    fake_adapter = make_fake_adapter(tag: "fake_b", matches: false)

    with_adapter_list([ fake_adapter ]) do
      assert_nil ProtocolAdapters::Base.resolve(@contract)
    end
  end

  test "resolve caches the detection result (subsequent calls skip matches?)" do
    matches_called = 0
    fake_adapter = Class.new(ProtocolAdapters::Base) do
      define_singleton_method(:type_tag) { "fake_c" }
    end
    fake_adapter.define_singleton_method(:matches?) do |_c|
      matches_called += 1
      true
    end
    # Force proc capture for closure on matches_called
    fake_adapter.instance_variable_set(:@captured_count, -> { matches_called })

    with_adapter_list([ fake_adapter ]) do
      ProtocolAdapters::Base.resolve(@contract)
      ProtocolAdapters::Base.resolve(@contract)
      ProtocolAdapters::Base.resolve(@contract)
    end

    assert_equal 1, matches_called
  end

  test "resolve picks the first matching adapter in registration order" do
    no_match = make_fake_adapter(tag: "no_match", matches: false)
    first    = make_fake_adapter(tag: "first",    matches: true)
    second   = make_fake_adapter(tag: "second",   matches: true)

    with_adapter_list([ no_match, first, second ]) do
      result = ProtocolAdapters::Base.resolve(@contract)
      assert_instance_of first, result
    end
  end

  # Default display_name is nil so ERC-20-ish adapters that don't override
  # it fall through to the on-chain name()/symbol() branch of
  # contract_display_name. Overriding is opt-in per adapter.
  test "display_name defaults to nil" do
    adapter_class = make_fake_adapter(tag: "no_display_override", matches: true)
    adapter = adapter_class.new(@contract)
    assert_nil adapter.display_name
  end

  private

  def make_fake_adapter(tag:, matches:)
    Class.new(ProtocolAdapters::Base) do
      define_singleton_method(:type_tag) { tag }
      define_singleton_method(:matches?) { |_c| matches }
    end
  end

  def with_adapter_list(adapters)
    stub_class_method(ProtocolAdapters::Base, :adapter_classes, -> { adapters }) do
      yield
    end
  end
end
