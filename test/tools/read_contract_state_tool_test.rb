require "test_helper"

class ReadContractStateToolTest < ActiveSupport::TestCase
  setup do
    @tool = ReadContractStateTool.new
    @contract = contracts(:uni_token)
  end

  test "returns error for unknown chain" do
    result = @tool.call(chain: "solana", address: "0x0", function_name: "x")
    assert_equal "unknown chain: solana", result[:error]
  end

  test "returns error when contract not indexed" do
    # Deliberately an address that isn't in contracts.yml fixture.
    result = @tool.call(chain: "eth", address: "0x" + "f" * 40, function_name: "totalSupply")
    assert_match(/not indexed/, result[:error])
  end

  test "returns decoded values on successful call" do
    stub_success([ 42 ]) do
      result = @tool.call(chain: "eth", address: @contract.address, function_name: "totalSupply")
      assert result[:success]
      assert_equal [ 42 ], result[:values]
    end
  end

  test "forwards positional args to SingleCaller" do
    captured = {}
    stub = lambda do |contract:, function_name:, args:|
      captured[:args] = args
      ChainReader::SingleCaller::Result.new(success: true, values: [ 0 ])
    end

    stub_class_method(ChainReader::SingleCaller, :call, stub) do
      @tool.call(chain: "eth", address: @contract.address, function_name: "balanceOf",
                 args: [ "0x0000000000000000000000000000000000000001" ])
    end

    assert_equal [ "0x0000000000000000000000000000000000000001" ], captured[:args]
  end

  test "returns success=false with message when function is not on the ABI" do
    raising = ->(**_) { raise ChainReader::SingleCaller::FunctionNotFound, "no function named 'bogus'" }
    stub_class_method(ChainReader::SingleCaller, :call, raising) do
      result = @tool.call(chain: "eth", address: @contract.address, function_name: "bogus")
      refute result[:success]
      assert_match(/bogus/, result[:error])
    end
  end

  test "exposes block_number alongside values for AI consumers" do
    typed = ChainReader::SingleCaller::Result.new(
      success: true, values: [ 42 ], error: nil,
      block_number: 24_500_000, fetched_at: Time.current
    )
    stub_class_method(ChainReader::SingleCaller, :call, ->(**_) { typed }) do
      result = @tool.call(chain: "eth", address: @contract.address, function_name: "totalSupply")
      assert result[:success]
      assert_equal 24_500_000, result[:block_number],
                   "AI agents need a block anchor to verify the read against on-chain state"
    end
  end

  test "block_number key is present (possibly nil) on success when SingleCaller couldn't get it" do
    no_block = ChainReader::SingleCaller::Result.new(
      success: true, values: [ 1 ], error: nil, block_number: nil, fetched_at: Time.current
    )
    stub_class_method(ChainReader::SingleCaller, :call, ->(**_) { no_block }) do
      result = @tool.call(chain: "eth", address: @contract.address, function_name: "totalSupply")
      assert result.key?(:block_number),
             "block_number must always be present in the response shape, even when nil"
      assert_nil result[:block_number]
    end
  end

  test "returns success=false when RPC errors out inside SingleCaller" do
    failed = ChainReader::SingleCaller::Result.new(success: false, error: "execution reverted")
    stub_class_method(ChainReader::SingleCaller, :call, ->(**_) { failed }) do
      result = @tool.call(chain: "eth", address: @contract.address, function_name: "totalSupply")
      refute result[:success]
      assert_equal "execution reverted", result[:error]
    end
  end

  test "accepts a slug instead of chain+address" do
    @contract.update!(address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984") # matches uni-eth
    stub_success([ 1_000_000 ]) do
      result = @tool.call(slug: "uni-eth", function_name: "totalSupply")
      assert result[:success]
      assert_equal [ 1_000_000 ], result[:values]
    end
  end

  test "returns error for unknown slug" do
    result = @tool.call(slug: "nonexistent-eth", function_name: "totalSupply")
    assert_match(/unknown slug/, result[:error])
  end

  test "returns error when neither slug nor chain+address is provided" do
    result = @tool.call(function_name: "totalSupply")
    assert_match(/either.*slug.*chain.*address/, result[:error])
  end

  private

  def stub_success(values, &block)
    result = ChainReader::SingleCaller::Result.new(success: true, values: values)
    stub_class_method(ChainReader::SingleCaller, :call, ->(**_) { result }, &block)
  end
end
