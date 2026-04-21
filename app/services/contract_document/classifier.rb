module ContractDocument
  # Matches a contract against known protocol templates and returns the most
  # specific match, or nil. Uses selector-subset matching: a template matches
  # when every required_selector is present in the contract's ABI.
  #
  # Templates never change at runtime, and bytecode never changes post-deploy,
  # so we cache the classification for 30 days in Solid Cache.
  class Classifier
    CACHE_TTL = 30.days

    def self.call(contract)
      new(contract).call
    end

    def initialize(contract)
      @contract = contract
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { match_template }
    end

    private

    def match_template
      selectors = contract_selectors
      return nil if selectors.empty?

      ProtocolTemplate
        .where(match_type: "required_selectors")
        .by_priority
        .find { |tmpl| tmpl.required_selectors_set.subset?(selectors) }
    end

    def contract_selectors
      return Set.new unless @contract.abi.is_a?(Array)

      @contract.abi
        .select { |item| item["type"] == "function" }
        .map { |fn| ChainReader::Base.selector(ChainReader::Base.function_signature(fn)) }
        .map(&:downcase)
        .to_set
    end

    def cache_key
      "classifier:#{@contract.chain.slug}:#{@contract.address}"
    end
  end
end
