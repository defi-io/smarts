# Extracts NatSpec comments (@notice, @dev, @param, @return) from Solidity
# source code and keys them by function/event name.
#
# Handles three source-code shapes Etherscan returns:
#   1. Plain Solidity string
#   2. JSON object {"path/File.sol": {"content": "..."}}
#   3. Solidity standard-JSON input, wrapped in double braces ({{ ... }})
#
# Overloaded functions: first occurrence wins (rare in practice).
class NatSpecExtractor
  TAG_NOTICE = "@notice"
  TAG_DEV    = "@dev"
  TAG_PARAM  = "@param"
  TAG_RETURN = "@return"

  def self.call(source_code)
    new(source_code).call
  end

  def initialize(source_code)
    @source_code = source_code
  end

  def call
    return {} if @source_code.blank?

    merged = { "functions" => {}, "events" => {} }

    files_from(@source_code).each do |_path, content|
      extract_from_content(content).each do |kind, docs|
        docs.each { |name, doc| merged[kind][name] ||= doc }
      end
    end

    merged.reject { |_, v| v.empty? }
  end

  private

  def files_from(code)
    s = code.strip
    return { "contract.sol" => s } unless s.start_with?("{")

    unwrapped = (s.start_with?("{{") && s.end_with?("}}")) ? s[1..-2] : s
    json = JSON.parse(unwrapped)

    if json["sources"].is_a?(Hash)
      json["sources"].transform_values { |v| v["content"].to_s }
    elsif json.values.first.is_a?(Hash) && json.values.first["content"]
      json.transform_values { |v| v["content"].to_s }
    else
      { "contract.sol" => s }
    end
  rescue JSON::ParserError
    { "contract.sol" => code }
  end

  def extract_from_content(content)
    result = { "functions" => {}, "events" => {} }

    pattern = %r{
      (?<comment>
        (?:^[ \t]*///[^\n]*\n)+
        |
        /\*\*(?:[^*]|\*(?!/))*\*/
      )
      \s*
      (?<kind>function|event)\s+(?<name>[A-Za-z_]\w*)
    }mx

    content.scan(pattern) do
      m = Regexp.last_match
      doc = parse_comment(m[:comment])
      next if doc.empty?

      bucket = m[:kind] == "function" ? "functions" : "events"
      result[bucket][m[:name]] ||= doc
    end

    result
  end

  def parse_comment(raw)
    lines = clean_comment_lines(raw)
    doc = { "notice" => nil, "dev" => nil, "params" => {}, "returns" => [] }

    current_tag = nil
    current_param = nil

    lines.each do |line|
      case line
      when /\A#{TAG_NOTICE}\s*(.*)/
        current_tag, current_param = :notice, nil
        doc["notice"] = $1.strip
      when /\A#{TAG_DEV}\s*(.*)/
        current_tag, current_param = :dev, nil
        doc["dev"] = $1.strip
      when /\A#{TAG_PARAM}\s+(\w+)\s*(.*)/
        current_tag, current_param = :param, $1
        doc["params"][current_param] = $2.strip
      when /\A#{TAG_RETURN}\s*(.*)/
        current_tag, current_param = :return, nil
        doc["returns"] << $1.strip
      when /\A@/
        current_tag, current_param = :unknown, nil
      else
        next if line.empty?
        case current_tag
        when :notice then doc["notice"] = join_line(doc["notice"], line)
        when :dev    then doc["dev"]    = join_line(doc["dev"], line)
        when :param  then doc["params"][current_param] = join_line(doc["params"][current_param], line)
        when :return then doc["returns"][-1] = join_line(doc["returns"][-1], line)
        end
      end
    end

    # Comments without any explicit tag: treat whole block as implicit notice.
    if doc.values.all? { |v| v.nil? || v.respond_to?(:empty?) && v.empty? }
      implicit = lines.reject(&:empty?).reject { |l| l.start_with?("@") }.join(" ").strip
      doc["notice"] = implicit if implicit.present?
    end

    doc.compact.reject { |_, v| v.respond_to?(:empty?) && v.empty? }
  end

  def clean_comment_lines(raw)
    raw
      .gsub(/^[ \t]*\/\/\/\s?/, "")
      .gsub(/^[ \t]*\/\*\*\s?/, "")
      .gsub(/\s*\*\/\s*\z/, "")
      .gsub(/^[ \t]*\*[ \t]?/, "")
      .split("\n")
      .map(&:strip)
  end

  def join_line(existing, line)
    existing.nil? || existing.empty? ? line : "#{existing} #{line}"
  end
end
