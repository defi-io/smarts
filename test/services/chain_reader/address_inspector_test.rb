require "test_helper"

class ChainReader::AddressInspectorTest < ActiveSupport::TestCase
  ADDR = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045".freeze

  # Minimal stand-in for an Eth::Client that responds to just the methods
  # AddressInspector calls.
  class FakeClient
    def initialize(code:, balance:, tx_count:, raise_on: nil)
      @code = code
      @balance = balance
      @tx_count = tx_count
      @raise_on = raise_on
    end

    def eth_get_code(_addr, _block)
      raise "boom" if @raise_on == :code
      { "jsonrpc" => "2.0", "id" => 1, "result" => @code }
    end

    def get_balance(_addr)
      raise "boom" if @raise_on == :balance
      @balance
    end

    def eth_get_transaction_count(_addr, _block)
      raise "boom" if @raise_on == :tx_count
      { "jsonrpc" => "2.0", "id" => 1, "result" => format("0x%x", @tx_count) }
    end
  end

  setup do
    @chain = chains(:ethereum)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  def with_fake_client(client)
    stub_class_method(ChainReader::Base, :client_for, ->(_c) { client }) do
      stub_class_method(ChainReader::EnsResolver, :call, ->(**_) { nil }) do
        yield
      end
    end
  end

  test "plain EOA: is_contract=false, balance+tx_count returned" do
    client = FakeClient.new(code: "0x", balance: 1_800_000_000_000_000_000, tx_count: 42)

    with_fake_client(client) do
      r = ChainReader::AddressInspector.call(chain: @chain, address: ADDR)

      assert_equal false, r.is_contract
      assert r.eoa?
      assert_equal 1_800_000_000_000_000_000, r.balance_wei
      assert_in_delta 1.8, r.balance_eth, 1e-9
      assert_equal 42, r.tx_count
    end
  end

  test "EIP-7702 delegated EOA (code starts with 0xef0100) classified as EOA, not contract" do
    client = FakeClient.new(
      code: "0xef01005a7fc11397e9a8ad41bf10bf13f22b0a63f96f6d",
      balance: 0,
      tx_count: 1
    )

    with_fake_client(client) do
      r = ChainReader::AddressInspector.call(chain: @chain, address: ADDR)
      assert_equal false, r.is_contract, "0xef0100 designator is a delegated EOA, not a contract"
    end
  end

  test "contract with real bytecode: is_contract=true" do
    client = FakeClient.new(code: "0x60806040526004361061...", balance: 0, tx_count: 1)

    with_fake_client(client) do
      r = ChainReader::AddressInspector.call(chain: @chain, address: ADDR)
      assert_equal true, r.is_contract
      refute r.eoa?
    end
  end

  test "populates ens_name when EnsResolver returns a name" do
    client = FakeClient.new(code: "0x", balance: 0, tx_count: 1)

    stub_class_method(ChainReader::Base, :client_for, ->(_c) { client }) do
      stub_class_method(ChainReader::EnsResolver, :call, ->(**_) { "vitalik.eth" }) do
        r = ChainReader::AddressInspector.call(chain: @chain, address: ADDR)
        assert_equal "vitalik.eth", r.ens_name
      end
    end
  end

  test "individual RPC failures degrade gracefully (nil field, not crash)" do
    client = FakeClient.new(code: "0x", balance: 1, tx_count: 1, raise_on: :code)

    with_fake_client(client) do
      r = ChainReader::AddressInspector.call(chain: @chain, address: ADDR)
      # code fetch failed → is_contract resolves via code_has_bytecode?(nil) → nil
      assert_nil r.is_contract
      # others still fine
      assert_equal 1, r.balance_wei
      assert_equal 1, r.tx_count
    end
  end
end
