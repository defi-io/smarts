require "test_helper"

class GetContractSourceToolTest < ActiveSupport::TestCase
  setup do
    @tool = GetContractSourceTool
    @contract = contracts(:uni_token)
  end

  # ---------- resolve_contract paths (shared with other tools, smoke only) ----------

  test "returns error for unknown chain slug" do
    result = @tool.payload(chain: "solana", address: "0x0")
    assert_equal "unknown chain: solana", result[:error]
  end

  test "returns error when contract is not indexed" do
    result = @tool.payload(chain: "eth", address: "0x" + "0" * 40)
    assert_match(/not indexed/, result[:error])
  end

  test "returns error when neither slug nor chain+address provided" do
    result = @tool.payload
    assert_match(/either.*slug.*chain.*address/, result[:error])
  end

  test "returns error when contract has no source code" do
    @contract.update!(source_code: nil)
    result = @tool.payload(chain: "eth", address: @contract.address)
    assert_match(/source not indexed/, result[:error])
  end

  test "rejects passing both file and search" do
    @contract.update!(source_code: "contract Foo {}")
    result = @tool.payload(chain: "eth", address: @contract.address, file: "contract.sol", search: "Foo")
    assert_match(/either.*file.*search/, result[:error])
  end

  # ---------- index mode (no file, no search) ----------

  test "index mode lists a plain-Solidity source as a single file" do
    @contract.update!(source_code: "contract Foo { uint x; }")
    result = @tool.payload(chain: "eth", address: @contract.address)

    assert_equal 1, result[:total_files]
    assert_equal "contract.sol", result[:files].first[:path]
    assert_equal "contract Foo { uint x; }".bytesize, result[:total_bytes]
    assert_equal "contract Foo { uint x; }".bytesize, result[:files].first[:bytes]
    assert_equal @contract.compiler_version, result[:compiler_version]
    assert_equal "eth", result[:chain]
  end

  test "index mode handles multi-file JSON source" do
    multi = {
      "Token.sol" => { "content" => "contract Token {}" },
      "Util.sol"  => { "content" => "library Util {}" }
    }.to_json
    @contract.update!(source_code: multi)
    result = @tool.payload(chain: "eth", address: @contract.address)

    assert_equal 2, result[:total_files]
    paths = result[:files].map { |f| f[:path] }
    assert_includes paths, "Token.sol"
    assert_includes paths, "Util.sol"
  end

  # ---------- file mode ----------

  test "file mode returns content for exact-path match" do
    multi = { "Token.sol" => { "content" => "contract Token { uint y; }" } }.to_json
    @contract.update!(source_code: multi)

    result = @tool.payload(chain: "eth", address: @contract.address, file: "Token.sol")
    assert_equal "Token.sol", result[:path]
    assert_equal "contract Token { uint y; }", result[:content]
    assert_equal false, result[:truncated]
    assert_equal "contract Token { uint y; }".bytesize, result[:bytes]
  end

  test "file mode resolves basename when path is nested" do
    multi = {
      "lib/Util.sol" => { "content" => "library Util {}" },
      "Token.sol"    => { "content" => "contract T {}" }
    }.to_json
    @contract.update!(source_code: multi)

    result = @tool.payload(chain: "eth", address: @contract.address, file: "Util.sol")
    assert_equal "lib/Util.sol", result[:path]
    assert_equal "library Util {}", result[:content]
  end

  test "file mode reports unknown file with the available list" do
    @contract.update!(source_code: "contract Foo {}")
    result = @tool.payload(chain: "eth", address: @contract.address, file: "Bar.sol")
    assert_match(/file not found/, result[:error])
    assert_equal [ "contract.sol" ], result[:available]
  end

  test "file mode flags ambiguous basenames" do
    multi = {
      "a/Token.sol" => { "content" => "contract A {}" },
      "b/Token.sol" => { "content" => "contract B {}" }
    }.to_json
    @contract.update!(source_code: multi)
    result = @tool.payload(chain: "eth", address: @contract.address, file: "Token.sol")
    assert_match(/ambiguous/, result[:error])
    assert_equal [ "a/Token.sol", "b/Token.sol" ], result[:candidates].sort
  end

  test "file mode truncates content exceeding MAX_FILE_CHARS" do
    big = "x" * (GetContractSourceTool::MAX_FILE_CHARS + 100)
    @contract.update!(source_code: big)
    result = @tool.payload(chain: "eth", address: @contract.address, file: "contract.sol")
    assert_equal true, result[:truncated]
    assert_equal GetContractSourceTool::MAX_FILE_CHARS, result[:content].length
    assert_equal big.bytesize, result[:bytes]
  end

  # ---------- search mode ----------

  test "search mode returns path/line/snippet hits" do
    multi = {
      "Token.sol" => { "content" => "contract Token {\n  function transfer(address to) external {}\n}" },
      "Util.sol"  => { "content" => "library Util { function noop() pure {} }" }
    }.to_json
    @contract.update!(source_code: multi)

    result = @tool.payload(chain: "eth", address: @contract.address, search: "transfer")
    assert_equal "transfer", result[:query]
    assert_equal 1, result[:hit_count]
    assert_equal false, result[:truncated]
    hit = result[:hits].first
    assert_equal "Token.sol", hit[:path]
    assert_equal 2, hit[:line]
    assert_match(/transfer\(address to\) external/, hit[:snippet])
  end

  test "search is case-insensitive" do
    @contract.update!(source_code: "contract Foo { function PAUSE() {} }")
    result = @tool.payload(chain: "eth", address: @contract.address, search: "pause")
    assert_equal 1, result[:hit_count]
  end

  test "search caps at MAX_SEARCH_HITS and marks truncated" do
    body = ([ "blacklist" ] * (GetContractSourceTool::MAX_SEARCH_HITS + 10)).join("\n")
    @contract.update!(source_code: body)
    result = @tool.payload(chain: "eth", address: @contract.address, search: "blacklist")
    assert_equal GetContractSourceTool::MAX_SEARCH_HITS, result[:hit_count]
    assert_equal true, result[:truncated]
  end

  test "search returns empty hits when nothing matches" do
    @contract.update!(source_code: "contract Foo {}")
    result = @tool.payload(chain: "eth", address: @contract.address, search: "nonexistent")
    assert_equal 0, result[:hit_count]
    assert_equal [], result[:hits]
    assert_equal false, result[:truncated]
  end

  test "blank or whitespace-only search falls back to index mode" do
    @contract.update!(source_code: "contract Foo {}")
    result = @tool.payload(chain: "eth", address: @contract.address, search: "  ")
    # Should behave as if `search` wasn't passed: return the file index.
    assert_equal 1, result[:total_files]
    assert_nil result[:hits]
  end

  test "search truncates very long snippets" do
    long_line = "blacklist " + ("x" * (GetContractSourceTool::SNIPPET_MAX_CHARS + 50))
    @contract.update!(source_code: long_line)
    result = @tool.payload(chain: "eth", address: @contract.address, search: "blacklist")
    snippet = result[:hits].first[:snippet]
    assert snippet.end_with?("…"), "expected snippet to be truncated with ellipsis"
    assert_equal GetContractSourceTool::SNIPPET_MAX_CHARS + 1, snippet.length
  end
end
