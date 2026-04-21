require "rouge"

module SourceCodeHelper
  # Etherscan returns the SourceCode field in one of three shapes:
  # 1. Plain Solidity text
  # 2. JSON: {"File.sol": {"content": "..."}}
  # 3. Solidity standard-input JSON wrapped in double braces: {{"sources": {...}}}
  #
  # Returns Array<{path:, content:}> so a multi-file contract renders as sub-tabs.
  def source_files(source_code)
    return [] if source_code.blank?

    s = source_code.strip
    files =
      if s.start_with?("{{") && s.end_with?("}}")
        parse_standard_json(s[1..-2])
      elsif s.start_with?("{")
        parse_json_shape(s)
      else
        { "contract.sol" => s }
      end

    files.map { |path, content| { path: path, content: content } }
  rescue JSON::ParserError
    [ { path: "contract.sol", content: source_code } ]
  end

  def highlight_solidity(content)
    lexer = Rouge::Lexers::Javascript.new
    formatter = Rouge::Formatters::HTML.new
    formatter.format(lexer.lex(content.to_s)).html_safe
  end

  def rouge_theme_stylesheet
    @rouge_theme_stylesheet ||= Rouge::Themes::Github.render(scope: ".highlight").html_safe
  end

  private

  def parse_standard_json(raw)
    json = JSON.parse(raw)
    if json["sources"].is_a?(Hash)
      json["sources"].transform_values { |v| v["content"].to_s }
    else
      { "contract.sol" => raw }
    end
  end

  def parse_json_shape(raw)
    json = JSON.parse(raw)
    if json["sources"].is_a?(Hash)
      json["sources"].transform_values { |v| v["content"].to_s }
    elsif json.values.first.is_a?(Hash) && json.values.first["content"]
      json.transform_values { |v| v["content"].to_s }
    else
      { "contract.sol" => raw }
    end
  end
end
