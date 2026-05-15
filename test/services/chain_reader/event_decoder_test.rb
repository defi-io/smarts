require "test_helper"

class ChainReader::EventDecoderTest < ActiveSupport::TestCase
  # ──────────────────────────────────────────────
  # event_signature & event_topic0 — ABI canonicalization
  # ──────────────────────────────────────────────

  test "event_signature concatenates input types into canonical form" do
    abi = event_abi("Transfer", [
      { "name" => "from",   "type" => "address", "indexed" => true },
      { "name" => "to",     "type" => "address", "indexed" => true },
      { "name" => "amount", "type" => "uint256" }
    ])
    assert_equal "Transfer(address,address,uint256)", ChainReader::EventDecoder.event_signature(abi)
  end

  test "event_signature expands tuple components instead of using literal 'tuple'" do
    abi = event_abi("Swap", [
      { "name" => "params", "type" => "tuple", "components" => [
        { "name" => "a", "type" => "uint256" },
        { "name" => "b", "type" => "address" }
      ] }
    ])
    assert_equal "Swap((uint256,address))", ChainReader::EventDecoder.event_signature(abi),
                 "tuple types must expand to (T1,T2) form for keccak to match Solidity"
  end

  test "event_topic0 is the keccak256 of the canonical signature" do
    abi = event_abi("Transfer", [
      { "name" => "from",   "type" => "address", "indexed" => true },
      { "name" => "to",     "type" => "address", "indexed" => true },
      { "name" => "amount", "type" => "uint256" }
    ])
    # ERC-20 Transfer signature is canonical and well-known.
    assert_equal "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                 ChainReader::EventDecoder.event_topic0(abi)
  end

  # ──────────────────────────────────────────────
  # call — happy path
  # ──────────────────────────────────────────────

  test "decodes Transfer event with indexed and non-indexed args" do
    abi = transfer_abi
    from = "0x" + "a" * 40
    to   = "0x" + "b" * 40
    log  = sample_log(
      topics: [ ChainReader::EventDecoder.event_topic0(abi), pad_address(from), pad_address(to) ],
      data:   pad_uint(1234)
    )

    result = ChainReader::EventDecoder.call(events_abi: [ abi ], log: log)

    assert_equal "Transfer", result.event_name
    assert_equal false,      result.anonymous
    assert_equal from,       result.args["from"]
    assert_equal to,         result.args["to"]
    assert_equal 1234,       result.args["amount"]
  end

  test "returns nil when no event in ABI matches topic0" do
    log = sample_log(topics: [ "0x" + "f" * 64 ], data: "0x")
    assert_nil ChainReader::EventDecoder.call(events_abi: [ transfer_abi ], log: log)
  end

  test "returns nil when log has no topics" do
    log = sample_log(topics: nil, data: "0x")
    assert_nil ChainReader::EventDecoder.call(events_abi: [ transfer_abi ], log: log)
  end

  # ──────────────────────────────────────────────
  # Indexed dynamic types — original is unrecoverable
  # ──────────────────────────────────────────────

  test "indexed string returns hashed wrapper, not garbage decoded value" do
    abi = event_abi("Named", [
      { "name" => "label", "type" => "string", "indexed" => true }
    ])
    hash_topic = "0x" + "ab" * 32
    log = sample_log(topics: [ ChainReader::EventDecoder.event_topic0(abi), hash_topic ], data: "0x")

    result = ChainReader::EventDecoder.call(events_abi: [ abi ], log: log)
    assert_equal({ hashed: hash_topic }, result.args["label"],
                 "indexed strings store keccak256(value) — original is unrecoverable")
  end

  test "indexed bytes returns hashed wrapper" do
    abi = event_abi("Bagged", [
      { "name" => "blob", "type" => "bytes", "indexed" => true }
    ])
    hash_topic = "0x" + "cd" * 32
    log = sample_log(topics: [ ChainReader::EventDecoder.event_topic0(abi), hash_topic ], data: "0x")

    result = ChainReader::EventDecoder.call(events_abi: [ abi ], log: log)
    assert_equal({ hashed: hash_topic }, result.args["blob"])
  end

  test "indexed array returns hashed wrapper" do
    abi = event_abi("MultiSent", [
      { "name" => "to", "type" => "address[]", "indexed" => true }
    ])
    hash_topic = "0x" + "ef" * 32
    log = sample_log(topics: [ ChainReader::EventDecoder.event_topic0(abi), hash_topic ], data: "0x")

    result = ChainReader::EventDecoder.call(events_abi: [ abi ], log: log)
    assert_equal({ hashed: hash_topic }, result.args["to"])
  end

  # ──────────────────────────────────────────────
  # Large integers — JSON-safe serialization
  # ──────────────────────────────────────────────

  test "uint256 larger than 2^53 is returned as a string for JSON safety" do
    abi = transfer_abi
    big = 2**100  # well beyond JS Number safe range

    log = sample_log(
      topics: [ ChainReader::EventDecoder.event_topic0(abi), pad_address("0x" + "0" * 40), pad_address("0x" + "0" * 40) ],
      data:   pad_uint(big)
    )

    result = ChainReader::EventDecoder.call(events_abi: [ abi ], log: log)
    assert_kind_of String, result.args["amount"], "JS clients lose precision >2^53; tool must emit string"
    assert_equal big.to_s, result.args["amount"]
  end

  test "small uint stays as integer" do
    abi = transfer_abi
    log = sample_log(
      topics: [ ChainReader::EventDecoder.event_topic0(abi), pad_address("0x" + "0" * 40), pad_address("0x" + "0" * 40) ],
      data:   pad_uint(42)
    )

    result = ChainReader::EventDecoder.call(events_abi: [ abi ], log: log)
    assert_equal 42, result.args["amount"]
    assert_kind_of Integer, result.args["amount"]
  end

  # ──────────────────────────────────────────────
  # Anonymous events — currently unsupported, must not crash
  # ──────────────────────────────────────────────

  test "anonymous event is returned as nil (caller falls back to Unknown)" do
    abi = event_abi("Hidden", [
      { "name" => "x", "type" => "uint256" }
    ], anonymous: true)
    # Anonymous events don't put the signature in topic[0]; we deliberately
    # use an arbitrary topic to mimic the indexed-arg-as-topic[0] reality.
    log = sample_log(topics: [ "0x" + "1" * 64 ], data: pad_uint(1))

    assert_nil ChainReader::EventDecoder.call(events_abi: [ abi ], log: log),
               "anonymous events have no signature topic — must return nil, not crash"
  end

  # ──────────────────────────────────────────────
  # Decoder failure tolerance — never throw upward
  # ──────────────────────────────────────────────

  test "corrupt non-indexed data falls back to nil-filled args, not exception" do
    abi = transfer_abi
    log = sample_log(
      topics: [ ChainReader::EventDecoder.event_topic0(abi), pad_address("0x" + "0" * 40), pad_address("0x" + "0" * 40) ],
      data:   "0xZZZZ"  # invalid hex / wrong length
    )

    result = ChainReader::EventDecoder.call(events_abi: [ abi ], log: log)
    refute_nil result, "decode_non_indexed must rescue and return Array.new(n) — outer call should still succeed"
    assert_equal "Transfer", result.event_name
    assert_nil result.args["amount"]
  end

  test "string-typed arg gets UTF-8 retagged when bytes are valid UTF-8" do
    abi = event_abi("WithName", [
      { "name" => "label", "type" => "string" }
    ])
    # ABI-encoded "hello" as one non-indexed string:
    # offset (0x20) + length (5) + content padded to 32 bytes.
    encoded = ([ 32, 5 ].pack("Q>Q>") + "hello".ljust(32, "\x00")).unpack1("H*")
    # re-encode properly using Eth::Abi to avoid manual byte mistakes
    encoded = Eth::Abi.encode([ "string" ], [ "hello" ]).unpack1("H*")

    log = sample_log(
      topics: [ ChainReader::EventDecoder.event_topic0(abi) ],
      data:   "0x" + encoded
    )

    result = ChainReader::EventDecoder.call(events_abi: [ abi ], log: log)
    assert_equal "hello", result.args["label"]
    assert_equal Encoding::UTF_8, result.args["label"].encoding,
                 "ABI strings come back ASCII-8BIT from Eth gem; must retag to UTF-8"
  end

  # ──────────────────────────────────────────────
  # Mixed-case topic0 — Etherscan/RPCs vary
  # ──────────────────────────────────────────────

  test "matches topic0 case-insensitively" do
    abi = transfer_abi
    upper_topic = ChainReader::EventDecoder.event_topic0(abi).upcase.sub(/\A0X/, "0x")
    log = sample_log(
      topics: [ upper_topic, pad_address("0x" + "0" * 40), pad_address("0x" + "0" * 40) ],
      data:   pad_uint(1)
    )

    result = ChainReader::EventDecoder.call(events_abi: [ abi ], log: log)
    refute_nil result, "Etherscan returns lowercase, some RPCs return mixed case — match must be normalized"
    assert_equal "Transfer", result.event_name
  end

  private

  def event_abi(name, inputs, anonymous: false)
    {
      "type"      => "event",
      "name"      => name,
      "inputs"    => inputs,
      "anonymous" => anonymous
    }
  end

  def transfer_abi
    event_abi("Transfer", [
      { "name" => "from",   "type" => "address", "indexed" => true },
      { "name" => "to",     "type" => "address", "indexed" => true },
      { "name" => "amount", "type" => "uint256" }
    ])
  end

  def sample_log(topics:, data:)
    { "topics" => topics, "data" => data }
  end

  def pad_address(addr)
    "0x" + ("0" * 24) + addr.sub(/\A0x/, "")
  end

  def pad_uint(value)
    "0x" + value.to_s(16).rjust(64, "0")
  end
end
