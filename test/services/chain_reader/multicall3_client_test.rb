require "test_helper"

class ChainReader::Multicall3ClientTest < ActiveSupport::TestCase
  setup do
    @chain = chains(:ethereum)
    @target = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
  end

  test "returns empty Batch for empty calls" do
    batch = ChainReader::Multicall3Client.call(chain: @chain, calls: [])
    assert_equal [], batch.results
    assert_nil batch.block_number
  end

  test "decodes multiple successful zero-arg calls" do
    calls = [
      call_for("name", [], [ "string" ]),
      call_for("symbol", [], [ "string" ]),
      call_for("decimals", [], [ "uint8" ]),
      call_for("totalSupply", [], [ "uint256" ])
    ]

    fake_response = encode_multicall_response([
      [ true, Eth::Abi.encode([ "string" ], [ "Uniswap" ]) ],
      [ true, Eth::Abi.encode([ "string" ], [ "UNI" ]) ],
      [ true, Eth::Abi.encode([ "uint8" ], [ 18 ]) ],
      [ true, Eth::Abi.encode([ "uint256" ], [ 10**27 ]) ]
    ], block_number: 19_234_567)

    stub_eth_call(fake_response) do
      batch = ChainReader::Multicall3Client.call(chain: @chain, calls: calls)
      results = batch.results
      assert_equal 4, results.size
      assert_equal [ "Uniswap" ], results[0].values
      assert_equal [ "UNI" ], results[1].values
      assert_equal [ 18 ], results[2].values
      assert_equal [ 10**27 ], results[3].values
      assert(results.all?(&:success))
      assert_equal 19_234_567, batch.block_number
    end
  end

  # Regression guard: Arbitrum USDT0's symbol() returns "USD₮0" (the ₮ glyph
  # is 3 UTF-8 bytes). Without retag_string_encoding, the ABI decoder hands
  # back an ASCII-8BIT string that collides with UTF-8 literals in ERB and
  # raises Encoding::CompatibilityError at render time.
  test "decoded string values are returned as UTF-8 when they're valid UTF-8" do
    calls = [ call_for("symbol", [], [ "string" ]) ]

    fake_response = encode_multicall_response([
      [ true, Eth::Abi.encode([ "string" ], [ "USD₮0" ]) ]
    ])

    stub_eth_call(fake_response) do
      batch = ChainReader::Multicall3Client.call(chain: @chain, calls: calls)
      assert_equal [ "USD₮0" ], batch.results[0].values
      assert_equal Encoding::UTF_8, batch.results[0].values.first.encoding,
                   "ABI `string` outputs must be tagged UTF-8 when their bytes are valid UTF-8"
    end
  end

  test "marks individual call as reverted while others succeed" do
    calls = [
      call_for("ok", [], [ "uint256" ]),
      call_for("boom", [], [ "uint256" ])
    ]

    fake_response = encode_multicall_response([
      [ true, Eth::Abi.encode([ "uint256" ], [ 42 ]) ],
      [ false, "".b ]
    ])

    stub_eth_call(fake_response) do
      results = ChainReader::Multicall3Client.call(chain: @chain, calls: calls).results
      assert results[0].success
      assert_equal [ 42 ], results[0].values
      refute results[1].success
      assert_equal "execution reverted", results[1].error
    end
  end

  test "encodes calls that take arguments into inner calldata" do
    calls = [
      ChainReader::Multicall3Client::Call.new(
        target: @target,
        function: {
          "name" => "balanceOf",
          "inputs" => [ { "type" => "address" } ],
          "outputs" => [ { "type" => "uint256" } ]
        },
        args: [ "0x0000000000000000000000000000000000000001" ]
      )
    ]

    fake_response = encode_multicall_response([ [ true, Eth::Abi.encode([ "uint256" ], [ 500 ]) ] ])
    captured = {}
    spy = ->(_chain, to:, data:) { captured[:data] = data; fake_response }

    stub_class_method(ChainReader::Base, :eth_call_hex, spy) do
      results = ChainReader::Multicall3Client.call(chain: @chain, calls: calls).results
      assert_equal [ 500 ], results[0].values
    end

    # outer calldata = aggregate3 selector + encoded [(target, true, inner), (multicall3, true, getBlockNumber)]
    # inner calldata = balanceOf selector + 32-byte padded address
    bal_selector = ChainReader::Base.selector("balanceOf(address)")
    assert_includes captured[:data], bal_selector[2..], "inner calldata should carry balanceOf selector"
    assert_includes captured[:data], "0" * 63 + "1", "inner calldata should carry the encoded address arg"
  end

  test "decodes tuple return value using components" do
    # Mimics Uniswap V3's slot0()-style struct return.
    fn = {
      "name" => "position",
      "inputs" => [],
      "outputs" => [ {
        "type" => "tuple",
        "components" => [
          { "type" => "uint160", "name" => "sqrtPriceX96" },
          { "type" => "int24",   "name" => "tick" },
          { "type" => "bool",    "name" => "locked" }
        ]
      } ]
    }
    calls = [ ChainReader::Multicall3Client::Call.new(target: @target, function: fn) ]

    inner_tuple = Eth::Abi.encode([ "(uint160,int24,bool)" ], [ [ 7919111111111, -42, true ] ])
    fake_response = encode_multicall_response([ [ true, inner_tuple ] ])

    stub_eth_call(fake_response) do
      results = ChainReader::Multicall3Client.call(chain: @chain, calls: calls).results
      assert results[0].success
      assert_equal [ [ 7919111111111, -42, true ] ], results[0].values
    end
  end

  test "returns success=false with decode error when return data is malformed" do
    calls = [ call_for("supply", [], [ "uint256" ]) ]

    # Claim success but return garbage bytes (too short to decode as uint256)
    fake_response = encode_multicall_response([ [ true, "ab".b ] ])

    stub_eth_call(fake_response) do
      results = ChainReader::Multicall3Client.call(chain: @chain, calls: calls).results
      refute results[0].success
      assert_match(/decode failed/, results[0].error)
    end
  end

  test "sends aggregate3 calldata with correct selector to Multicall3 address" do
    calls = [ call_for("totalSupply", [], [ "uint256" ]) ]
    fake_response = encode_multicall_response([ [ true, Eth::Abi.encode([ "uint256" ], [ 1 ]) ] ])

    captured = {}
    spy = ->(chain, to:, data:) {
      captured[:chain] = chain
      captured[:to] = to
      captured[:data] = data
      fake_response
    }

    stub_class_method(ChainReader::Base, :eth_call_hex, spy) do
      ChainReader::Multicall3Client.call(chain: @chain, calls: calls)
    end

    assert_equal ChainReader::Multicall3Client::ADDRESS, captured[:to]
    agg_selector = ChainReader::Base.selector("aggregate3((address,bool,bytes)[])")
    assert captured[:data].start_with?(agg_selector), "data should start with aggregate3 selector"
  end

  test "appends getBlockNumber call to Multicall3 itself for batch block height" do
    calls = [ call_for("totalSupply", [], [ "uint256" ]) ]
    fake_response = encode_multicall_response(
      [ [ true, Eth::Abi.encode([ "uint256" ], [ 1 ]) ] ],
      block_number: 21_000_000
    )

    captured = {}
    spy = ->(_chain, to:, data:) { captured[:data] = data; fake_response }

    stub_class_method(ChainReader::Base, :eth_call_hex, spy) do
      batch = ChainReader::Multicall3Client.call(chain: @chain, calls: calls)
      assert_equal 21_000_000, batch.block_number
    end

    block_selector = ChainReader::Base.selector("getBlockNumber()")
    multicall_addr_packed = ChainReader::Multicall3Client::ADDRESS.sub(/\A0x/, "").downcase
    assert_includes captured[:data], block_selector[2..],
                    "outer calldata should include getBlockNumber selector"
    assert_includes captured[:data].downcase, multicall_addr_packed,
                    "outer calldata should reference the multicall3 address as a target"
  end

  test "block_number is nil when the appended getBlockNumber call reverts" do
    calls = [ call_for("totalSupply", [], [ "uint256" ]) ]
    fake_response = encode_multicall_response(
      [ [ true, Eth::Abi.encode([ "uint256" ], [ 7 ]) ] ],
      block_tuple: [ false, "".b ]
    )

    stub_eth_call(fake_response) do
      batch = ChainReader::Multicall3Client.call(chain: @chain, calls: calls)
      assert_nil batch.block_number
      assert_equal [ 7 ], batch.results[0].values
    end
  end

  private

  def call_for(name, input_types, output_types)
    ChainReader::Multicall3Client::Call.new(
      target: @target,
      function: {
        "name" => name,
        "inputs" => input_types.map { |t| { "type" => t } },
        "outputs" => output_types.map { |t| { "type" => t } }
      }
    )
  end

  # Builds the aggregate3 return payload. The Multicall3Client internally
  # appends a getBlockNumber() call to every batch, so the encoded response
  # must carry one extra (success, bytes) tuple after the per-call ones.
  def encode_multicall_response(results, block_number: 12_345, block_tuple: nil)
    appended = block_tuple || [ true, Eth::Abi.encode([ "uint256" ], [ block_number ]) ]
    "0x" + Eth::Abi.encode([ "(bool,bytes)[]" ], [ results + [ appended ] ]).unpack1("H*")
  end

  def stub_eth_call(hex_response, &block)
    stub_class_method(ChainReader::Base, :eth_call_hex, ->(_chain, to:, data:) { hex_response }, &block)
  end
end
