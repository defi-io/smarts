require "test_helper"

class SourceCodeHelperTest < ActionView::TestCase
  test "source_files returns empty for blank input" do
    assert_equal [], source_files(nil)
    assert_equal [], source_files("")
  end

  test "source_files wraps plain Solidity in a single-entry list" do
    files = source_files("contract Foo {}")

    assert_equal 1, files.size
    assert_equal "contract.sol", files.first[:path]
    assert_equal "contract Foo {}", files.first[:content]
  end

  test "source_files handles Solidity standard-JSON with double braces" do
    raw = "{" + {
      language: "Solidity",
      sources: {
        "A.sol" => { "content" => "contract A {}" },
        "B.sol" => { "content" => "contract B {}" }
      }
    }.to_json + "}"

    files = source_files(raw)

    assert_equal 2, files.size
    paths = files.map { |f| f[:path] }
    assert_includes paths, "A.sol"
    assert_includes paths, "B.sol"
  end

  test "source_files handles single-file JSON map" do
    raw = { "Token.sol" => { "content" => "contract Token {}" } }.to_json

    files = source_files(raw)

    assert_equal 1, files.size
    assert_equal "Token.sol", files.first[:path]
    assert_equal "contract Token {}", files.first[:content]
  end

  test "source_files treats unparseable JSON as plain Solidity" do
    files = source_files("{not valid json")

    assert_equal 1, files.size
    assert_equal "contract.sol", files.first[:path]
  end

  test "highlight_solidity wraps tokens in span classes and is html_safe" do
    html = highlight_solidity("contract Foo { uint256 x = 1; }")

    assert html.html_safe?
    assert_match(/<span class=/, html)
  end

  test "rouge_theme_stylesheet returns html_safe CSS" do
    css = rouge_theme_stylesheet
    assert css.html_safe?
    assert_match(/\.highlight/, css)
  end
end
