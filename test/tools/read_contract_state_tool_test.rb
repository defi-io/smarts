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
    result = @tool.call(chain: "eth", address: "0x" + "1" * 40, function_name: "totalSupply")
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

  test "returns success=false when RPC errors out inside SingleCaller" do
    failed = ChainReader::SingleCaller::Result.new(success: false, error: "execution reverted")
    stub_class_method(ChainReader::SingleCaller, :call, ->(**_) { failed }) do
      result = @tool.call(chain: "eth", address: @contract.address, function_name: "totalSupply")
      refute result[:success]
      assert_equal "execution reverted", result[:error]
    end
  end

  private

  def stub_success(values, &block)
    result = ChainReader::SingleCaller::Result.new(success: true, values: values)
    stub_class_method(ChainReader::SingleCaller, :call, ->(**_) { result }, &block)
  end
end
