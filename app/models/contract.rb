class Contract < ApplicationRecord
  belongs_to :chain

  validates :address, presence: true
  validates :address, uniqueness: { scope: :chain_id }

  before_validation :normalize_address

  def display_address
    "#{address[0..5]}...#{address[-4..]}"
  end

  # SPDX license identifier parsed from the source code, when present. Solidity
  # convention since 2020 is a comment at the top of each file:
  #   // SPDX-License-Identifier: MIT
  # Older contracts (and some multi-file wrappers that don't forward the
  # identifier) return nil here, which is fine — callers should omit the field.
  SPDX_PATTERN = /SPDX-License-Identifier:\s*([A-Za-z0-9.\-+]+)/i

  def license
    return nil if source_code.blank?

    match = source_code.match(SPDX_PATTERN)
    match && match[1]
  end

  def view_functions
    return [] unless abi.is_a?(Array)

    abi.select { |item| item["type"] == "function" && item["stateMutability"].in?(%w[view pure]) }
  end

  def write_functions
    return [] unless abi.is_a?(Array)

    abi.select { |item| item["type"] == "function" && item["stateMutability"].in?(%w[nonpayable payable]) }
  end

  def events
    return [] unless abi.is_a?(Array)

    abi.select { |item| item["type"] == "event" }
  end

  # Merged real + AI docs for a function or event. Real NatSpec wins per-field;
  # the returned `source` hash tells the view whether each field came from
  # source code ("real") or Claude ("ai"). Empty hash means no docs at all.
  def natspec_for(kind, name)
    real = dig_spec(natspec, kind, name)
    ai   = dig_spec(ai_natspec, kind, name)
    return {} if real.blank? && ai.blank?

    source = {}
    merged = {}

    %w[notice dev].each do |field|
      if real[field].to_s.strip.present?
        merged[field] = real[field]
        source[field] = "real"
      elsif ai[field].to_s.strip.present?
        merged[field] = ai[field]
        source[field] = "ai"
      end
    end

    merged["params"]  = merge_params(real["params"], ai["params"], source)
    merged["returns"] = merge_returns(real["returns"], ai["returns"], source)
    merged["source"]  = source
    merged
  end

  def all_functions_have_natspec?
    return true unless abi.is_a?(Array)

    (view_functions + write_functions).all? do |fn|
      dig_spec(natspec, "functions", fn["name"])["notice"].to_s.strip.present?
    end
  end

  private

  def dig_spec(spec, kind, name)
    return {} unless spec.is_a?(Hash)

    spec.dig(kind, name) || {}
  end

  def merge_params(real, ai, source)
    real_h = real.is_a?(Hash) ? real : {}
    ai_h   = ai.is_a?(Hash) ? ai : {}
    source["params"] = {}
    merged = {}

    (real_h.keys | ai_h.keys).each do |key|
      if real_h[key].to_s.strip.present?
        merged[key] = real_h[key]
        source["params"][key] = "real"
      elsif ai_h[key].to_s.strip.present?
        merged[key] = ai_h[key]
        source["params"][key] = "ai"
      end
    end

    merged
  end

  def merge_returns(real, ai, source)
    real_a = Array(real)
    ai_a   = Array(ai)
    max_len = [ real_a.length, ai_a.length ].max
    source["returns"] = Array.new(max_len)

    Array.new(max_len) do |i|
      if real_a[i].to_s.strip.present?
        source["returns"][i] = "real"
        real_a[i]
      elsif ai_a[i].to_s.strip.present?
        source["returns"][i] = "ai"
        ai_a[i]
      end
    end.compact
  end

  def normalize_address
    self.address = address&.downcase
  end
end
