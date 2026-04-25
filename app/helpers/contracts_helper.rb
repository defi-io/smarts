require "bigdecimal"
require "bigdecimal/util"

module ContractsHelper
  # Dispatches by ABI output shape: tuples → (name: val, ...), arrays → [...],
  # scalars → format_abi_value. Prefer this over format_abi_value when you have
  # the full output hash (with components for tuples).
  def format_abi_output(value, output)
    type = output["type"].to_s
    if type == "tuple"
      format_tuple(value, Array(output["components"]))
    elsif type.start_with?("tuple[")
      suffix = type.sub(/\Atuple/, "")
      if suffix == "[]"
        "[" + Array(value).map { |v| format_tuple(v, Array(output["components"])) }.join(", ") + "]"
      else
        # Fixed-size tuple array like tuple[2]: treat as array of tuples
        "[" + Array(value).map { |v| format_tuple(v, Array(output["components"])) }.join(", ") + "]"
      end
    else
      format_abi_value(value, type)
    end
  end

  # Format a single decoded ABI value for inline display.
  # Types handled: uint/int*, bool, address, string, bytes*, arrays (shallow).
  def format_abi_value(value, type)
    case type
    when /\A(u?int)(\d*)\z/
      format_integer(value)
    when "bool"
      value ? "true" : "false"
    when "address"
      value.to_s.downcase
    when "string"
      value.to_s.length > 80 ? "#{value.to_s[0, 77]}..." : value.to_s
    when /\Abytes\d+\z/, "bytes"
      "0x" + value.to_s.unpack1("H*")
    when /\A(.+)\[\]\z/
      inner = $1
      "[" + Array(value).map { |v| format_abi_value(v, inner) }.join(", ") + "]"
    else
      value.inspect
    end
  end

  # Given a Multicall3Client::Result + ABI function hash, return an inline HTML-safe
  # string ready to drop next to the function name. Returns nil if there's nothing useful.
  def render_live_result(result, fn)
    return nil unless result

    if !result.success
      return content_tag(:span, "reverted", class: "text-error text-xs font-mono")
    end

    outputs = Array(fn["outputs"])
    return nil if outputs.empty? || result.values.empty?

    parts = result.values.each_with_index.map do |v, i|
      smart_format_output(v, outputs[i], fn)
    end

    content_tag(:span, "→ #{parts.join(', ')}", class: "text-success text-xs font-mono break-all")
  end

  # Block-anchored freshness tag for a single read. The block number is the
  # objective anchor; the "X ago" timestamp tells you how long since we wrote
  # it to cache (not how far behind chain head). Suppressed for immutable
  # functions and when we have no block_number to anchor on.
  def freshness_tag_for(fn)
    return nil unless @live_snapshot&.block_number
    return nil unless fn.is_a?(Hash)

    mutability = ChainReader::FieldMutability.classify(fn["name"])
    return nil if mutability == :immutable

    block_text = "Block ##{number_with_delimiter(@live_snapshot.block_number)}"
    label =
      if mutability == :fast && @live_snapshot.fetched_at
        "as of #{block_text} · #{freshness_phrase(@live_snapshot.fetched_at)}"
      else
        "as of #{block_text}"
      end

    content_tag(:span, label, class: "text-xs opacity-50 font-mono ml-2",
                title: "Read at chain block ##{@live_snapshot.block_number}; cached for up to 60s.")
  end

  # Block-anchored freshness header for protocol adapter panels (Uniswap V3,
  # ERC-20). Reads block_number + fetched_at off the panel data hash. Returns
  # nil if either is missing (older cached payload still in flight).
  def panel_freshness_tag(data)
    return nil unless data.is_a?(Hash)

    block = data[:block_number]
    return nil unless block

    fetched = data[:fetched_at]
    label =
      if fetched
        "as of Block ##{number_with_delimiter(block)} · #{freshness_phrase(fetched)}"
      else
        "as of Block ##{number_with_delimiter(block)}"
      end

    content_tag(:span, label, class: "text-xs opacity-60 font-mono",
                title: "Read at chain block ##{block}; cached for up to 60s.")
  end

  # Compact "23s" / "4m" / "1h" formatter. Returns "now" for sub-second /
  # missing input. Use freshness_phrase for the user-facing "23s ago" form.
  def time_ago_short(time)
    return "now" unless time
    seconds = (Time.current - time).to_i
    return "now" if seconds < 1
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600
    "#{seconds / 3600}h"
  end

  # User-facing phrase: "just now" when sub-second, "23s ago" / "4m ago" /
  # "2h ago" otherwise. Avoids the awkward "now ago" rendering.
  def freshness_phrase(time)
    return "just now" unless time
    seconds = (Time.current - time).to_i
    return "just now" if seconds < 1
    "#{time_ago_short(time)} ago"
  end

  # User-facing block explorer base URL per supported chain. Used by
  # dual-link renderers that want the "↗ Etherscan" counterpart to an
  # on-smarts-md link. Returns nil for unknown chains.
  EXPLORER_BASE_URLS = {
    "eth"      => "https://etherscan.io",
    "base"     => "https://basescan.org",
    "arbitrum" => "https://arbiscan.io",
    "optimism" => "https://optimistic.etherscan.io",
    "polygon"  => "https://polygonscan.com"
  }.freeze

  def explorer_address_url(chain, address)
    base = EXPLORER_BASE_URLS[chain.slug]
    return nil unless base

    "#{base}/address/#{address}"
  end

  def explorer_name(chain)
    case chain.slug
    when "eth"      then "Etherscan"
    when "base"     then "Basescan"
    when "arbitrum" then "Arbiscan"
    when "optimism" then "Etherscan"
    when "polygon"  then "Polygonscan"
    else "explorer"
    end
  end

  # Brand-first display name with fallback chain.
  #
  # Etherscan returns the Solidity class name (e.g. "FiatTokenV2_2",
  # "UniswapV3Pool") for many contracts. That's on `contract.name`, but it's
  # rarely what users want to see. We check, in order:
  #
  #   1. Protocol adapter's `display_name` — for non-ERC-20 shapes where the
  #      on-chain name()/symbol() don't exist or aren't descriptive. Example:
  #      UniswapV3Adapter composes "USDC/WETH 0.05%" from token0/token1/fee.
  #   2. On-chain `name()` — ERC-20 brand name ("USD Coin").
  #   3. On-chain `symbol()` — ticker fallback ("USDC").
  #   4. `contract.name` — whatever Etherscan handed us.
  #   5. "Unknown Contract" — final safety net.
  def contract_display_name
    @protocol_adapter&.display_name.to_s.presence ||
      live_value("name()").to_s.presence ||
      live_value("symbol()").to_s.presence ||
      @contract&.name.presence ||
      "Unknown Contract"
  end

  # Truncated "0xa0b8…eb48" for inline display. First 6 + last 4.
  def truncate_address(addr)
    return nil unless addr.is_a?(String) && addr.start_with?("0x") && addr.length >= 12

    "#{addr[0, 6]}…#{addr[-4..]}"
  end

  # Formats a wei amount to a human-friendly eth-units string rounded to 2dp.
  # Returns nil for nil input.
  def format_native_balance(wei, symbol)
    return nil if wei.nil?

    eth = wei.to_d / BigDecimal("1e18")
    rounded = eth.round(2, BigDecimal::ROUND_DOWN)
    whole, frac = rounded.to_s("F").split(".")
    whole_fmt = whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
    frac_padded = (frac.to_s + "00")[0, 2]
    body = frac_padded == "00" ? whole_fmt : "#{whole_fmt}.#{frac_padded}"
    "#{body} #{symbol}"
  end

  # Higher-precision version for developers. Six decimals, no rounding-down.
  def format_native_balance_precise(wei, symbol)
    return nil if wei.nil?

    eth = wei.to_d / BigDecimal("1e18")
    rounded = eth.round(6, BigDecimal::ROUND_DOWN)
    whole, frac = rounded.to_s("F").split(".")
    whole_fmt = whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
    frac_padded = (frac.to_s + "000000")[0, 6]
    "#{whole_fmt}.#{frac_padded} #{symbol}"
  end

  # Small inline marker shown next to AI-generated doc text. Returns nil if
  # the source is "real" or missing so callers can safely `<%= %>` it.
  def ai_badge(source_value)
    return nil unless source_value == "ai"

    content_tag(:span, "✨ AI", class: "badge badge-xs badge-ghost opacity-70 ml-1",
                title: "Generated by Claude from the ABI, not the original source.")
  end

  # Builds a human-readable signature with named parameters:
  # balanceOf(account: address)  —  omits names when unnamed.
  def function_signature_with_params(fn)
    inputs = Array(fn["inputs"])
    return "#{fn['name']}()" if inputs.empty?

    parts = inputs.map do |i|
      name = i["name"].to_s
      name.empty? ? i["type"] : "#{name}: #{i['type']}"
    end

    "#{fn['name']}(#{parts.join(', ')})"
  end

  # Same as format_abi_output but with protocol awareness: ERC-20 totalSupply()
  # returns raw uint256 wei, which is unreadable. If @classification marks this
  # contract as ERC-20 and decimals()/symbol() live values are available, render
  # "55,046,395,721.81 USDC" instead of "55,046,395,721,805,492".
  def smart_format_output(value, output, fn)
    if erc20_amount_function?(fn, output)
      scaled = scale_erc20_amount(value)
      return scaled if scaled
    end
    format_abi_output(value, output)
  end

  private

  def erc20_amount_function?(fn, output)
    return false unless @classification&.protocol_key == "erc20"
    return false unless fn["name"] == "totalSupply"

    output["type"].to_s.match?(/\Auint\d*\z/)
  end

  def scale_erc20_amount(raw)
    return nil unless raw.is_a?(Integer)
    decimals = erc20_decimals
    return nil unless decimals

    scaled = (raw.to_d / (BigDecimal(10) ** decimals)).round(2, BigDecimal::ROUND_DOWN)
    whole, frac = scaled.to_s("F").split(".")
    whole_formatted = whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
    frac_padded = (frac.to_s + "00")[0, 2]
    body = frac_padded == "00" ? whole_formatted : "#{whole_formatted}.#{frac_padded}"
    symbol = erc20_symbol
    symbol ? "#{body} #{symbol}" : body
  end

  def erc20_decimals
    live_value("decimals()").then { |v| v.is_a?(Integer) ? v : nil }
  end

  def erc20_symbol
    live_value("symbol()").then { |v| v.is_a?(String) ? v : nil }
  end

  def live_value(signature)
    result = @live_values&.dig(signature)
    return nil unless result&.success && result.values.any?
    result.values.first
  end

  def format_integer(n)
    return n.to_s unless n.is_a?(Integer)
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
  end

  def format_tuple(value, components)
    parts = components.each_with_index.map do |comp, i|
      v = Array(value)[i]
      rendered = format_abi_output(v, comp)
      name = comp["name"].to_s
      name.empty? ? rendered : "#{name}: #{rendered}"
    end
    "(#{parts.join(', ')})"
  end
end
