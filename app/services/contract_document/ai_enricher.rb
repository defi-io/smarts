module ContractDocument
  # Generates AI-drafted NatSpec for functions whose real source-derived
  # NatSpec is missing or empty. Uses Claude Haiku — cheap, sub-second per call.
  # Results cached 30 days per (abi_hash + prompt_version + function signature).
  class AiEnricher
    MODEL = "gpt-5-mini"
    PROMPT_VERSION = "v1"
    MAX_FUNCTIONS_PER_CONTRACT = 30
    CACHE_TTL = 30.days

    def self.call(contract)
      new(contract).call
    end

    def initialize(contract)
      @contract = contract
    end

    # Returns a natspec-shaped hash: { "functions" => { name => { "notice" => ..., "params" => {...}, "returns" => [...] } } }
    def call
      return { "functions" => {} } unless @contract.abi.is_a?(Array)

      targets = functions_needing_docs.first(MAX_FUNCTIONS_PER_CONTRACT)
      functions = {}

      targets.each do |fn|
        doc = describe_function(fn)
        functions[fn["name"]] = doc if doc.is_a?(Hash) && doc["notice"].present?
      end

      { "functions" => functions }
    end

    private

    def functions_needing_docs
      real = @contract.natspec.is_a?(Hash) ? @contract.natspec["functions"].to_h : {}

      (@contract.view_functions + @contract.write_functions).reject do |fn|
        real.dig(fn["name"], "notice").to_s.strip.present?
      end
    end

    def describe_function(fn)
      Rails.cache.fetch(cache_key(fn), expires_in: CACHE_TTL) do
        ask_claude(fn)
      end
    rescue => e
      Rails.logger.warn("[AiEnricher] failed for #{fn['name']}: #{e.class}: #{e.message}")
      nil
    end

    def ask_claude(fn)
      chat = RubyLLM.chat(model: MODEL)
      response = chat.ask(prompt_for(fn))
      parse_response(response.content, fn)
    end

    def prompt_for(fn)
      classification = Classifier.call(@contract)&.display_name || "generic Solidity contract"
      inputs_desc = inputs_lines(fn)
      returns_desc = outputs_lines(fn)
      protocol_context = protocol_context_lines

      <<~PROMPT
        You are documenting a Solidity smart contract function. Return JSON only — no prose, no markdown fences.

        Contract: #{@contract.name || '(unknown)'} (classified as #{classification})
        #{protocol_context}
        Function signature: #{signature(fn)}
        Mutability: #{fn['stateMutability']}
        Inputs:
        #{inputs_desc.presence || '  (none)'}
        Returns:
        #{returns_desc.presence || '  (none)'}

        Produce this exact JSON shape. Keep each string ≤ 120 chars. Use null for "dev" if no technical caveat is warranted. Empty objects/arrays are fine:

        {
          "notice": "One-sentence user-facing description, active voice.",
          "dev": null,
          "params": { "paramName": "Short description." },
          "returns": ["Description of each return value in order."]
        }
      PROMPT
    end

    def protocol_context_lines
      adapter = ProtocolAdapters::Base.resolve(@contract)
      return nil unless adapter.is_a?(ProtocolAdapters::PolymarketAdapter)

      lines = [
        "Protocol: #{adapter.protocol_name}",
        "Contract role: #{adapter.display_name}",
        "Architecture context: #{adapter.architecture_summary}"
      ]
      flow = adapter.architecture_flow
      lines << "Flow: #{flow.join(' -> ')}" if flow.present?
      comparison = adapter.exchange_comparison
      lines << "Exchange distinction: #{comparison[:same_abi_note]} #{comparison[:market_type]}." if comparison.present?
      lines.join("\n")
    rescue StandardError => e
      Rails.logger.warn("[AiEnricher] protocol context failed: #{e.class}: #{e.message}")
      nil
    end

    def parse_response(text, fn)
      raw = text.to_s.strip
      raw = raw.sub(/\A```(?:json)?/, "").sub(/```\z/, "").strip
      parsed = JSON.parse(raw)
      return nil unless parsed.is_a?(Hash) && parsed["notice"].is_a?(String)

      parsed.slice("notice", "dev", "params", "returns")
    rescue JSON::ParserError => e
      Rails.logger.warn("[AiEnricher] JSON parse failed for #{fn['name']}: #{e.message}. Raw: #{text[0, 200]}")
      nil
    end

    def signature(fn)
      types = Array(fn["inputs"]).map { |i| i["type"] }.join(",")
      "#{fn['name']}(#{types}) returns (#{Array(fn['outputs']).map { |o| o['type'] }.join(',')})"
    end

    def inputs_lines(fn)
      Array(fn["inputs"]).map do |i|
        "  - #{i['name'].presence || '(unnamed)'}: #{i['type']}"
      end.join("\n")
    end

    def outputs_lines(fn)
      Array(fn["outputs"]).map do |o|
        "  - #{o['name'].presence || '(unnamed)'}: #{o['type']}"
      end.join("\n")
    end

    def cache_key(fn)
      abi_hash = Digest::SHA1.hexdigest(@contract.abi.to_json)[0, 16]
      "ai_enricher:#{PROMPT_VERSION}:#{abi_hash}:#{signature(fn)}"
    end
  end
end
