require "test_helper"

class NatSpecExtractorTest < ActiveSupport::TestCase
  test "returns empty hash when source is blank" do
    assert_equal({}, NatSpecExtractor.call(nil))
    assert_equal({}, NatSpecExtractor.call(""))
    assert_equal({}, NatSpecExtractor.call("   "))
  end

  test "extracts block-comment NatSpec on a function" do
    source = <<~SOL
      contract Token {
          /**
           * @notice Transfers tokens.
           * @dev Reverts on insufficient balance.
           * @param to Recipient address.
           * @param amount Tokens to transfer.
           * @return success True on success.
           */
          function transfer(address to, uint256 amount) external returns (bool) {}
      }
    SOL

    doc = NatSpecExtractor.call(source)["functions"]["transfer"]

    assert_equal "Transfers tokens.", doc["notice"]
    assert_equal "Reverts on insufficient balance.", doc["dev"]
    assert_equal "Recipient address.", doc["params"]["to"]
    assert_equal "Tokens to transfer.", doc["params"]["amount"]
    assert_equal [ "success True on success." ], doc["returns"]
  end

  test "extracts single-line /// comments" do
    source = <<~SOL
      /// @notice Top-up.
      /// @param amount How much to add.
      function deposit(uint256 amount) external {}
    SOL

    doc = NatSpecExtractor.call(source)["functions"]["deposit"]
    assert_equal "Top-up.", doc["notice"]
    assert_equal "How much to add.", doc["params"]["amount"]
  end

  test "supports multi-line notice that continues across lines" do
    source = <<~SOL
      /**
       * @notice First line.
       *         Second line.
       *         Third line.
       */
      function foo() external {}
    SOL

    doc = NatSpecExtractor.call(source)["functions"]["foo"]
    assert_equal "First line. Second line. Third line.", doc["notice"]
  end

  test "extracts events separately from functions" do
    source = <<~SOL
      /// @notice Emitted when tokens move.
      /// @param from The sender.
      event Transfer(address from, address to, uint256 amount);

      /// @notice Moves tokens.
      function transfer(address to, uint256 amount) external {}
    SOL

    result = NatSpecExtractor.call(source)
    assert_equal "Emitted when tokens move.", result["events"]["Transfer"]["notice"]
    assert_equal "The sender.", result["events"]["Transfer"]["params"]["from"]
    assert_equal "Moves tokens.", result["functions"]["transfer"]["notice"]
  end

  test "treats tagless comment as implicit notice" do
    source = <<~SOL
      /// Just a plain description.
      function bar() external {}
    SOL

    assert_equal "Just a plain description.", NatSpecExtractor.call(source)["functions"]["bar"]["notice"]
  end

  test "parses Solidity standard-JSON multi-file shape with double-brace wrapping" do
    source = {
      language: "Solidity",
      sources: {
        "A.sol" => { "content" => "/// @notice From A\nfunction a() external {}" },
        "B.sol" => { "content" => "/// @notice From B\nfunction b() external {}" }
      }
    }.to_json

    result = NatSpecExtractor.call("{#{source}}")

    assert_equal "From A", result["functions"]["a"]["notice"]
    assert_equal "From B", result["functions"]["b"]["notice"]
  end

  test "parses single-file JSON map shape" do
    source = { "Token.sol" => { "content" => "/// @notice Single\nfunction s() external {}" } }.to_json

    doc = NatSpecExtractor.call(source)["functions"]["s"]
    assert_equal "Single", doc["notice"]
  end

  test "first occurrence wins when functions are overloaded across files" do
    source = {
      sources: {
        "First.sol" => { "content" => "/// @notice From First\nfunction overload() external {}" },
        "Second.sol" => { "content" => "/// @notice From Second\nfunction overload() external {}" }
      }
    }.to_json

    doc = NatSpecExtractor.call("{#{source}}")["functions"]["overload"]
    assert_equal "From First", doc["notice"]
  end

  test "skips declarations without preceding NatSpec" do
    source = <<~SOL
      function undocumented() external {}
      /// @notice Has a doc
      function documented() external {}
    SOL

    result = NatSpecExtractor.call(source)
    refute_includes result.fetch("functions", {}), "undocumented"
    assert_includes result["functions"], "documented"
  end

  test "gracefully recovers from malformed JSON source field" do
    assert_equal({}, NatSpecExtractor.call("{invalid json"))
  end
end
