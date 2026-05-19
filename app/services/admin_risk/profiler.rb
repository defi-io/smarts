# frozen_string_literal: true

require "set"

module AdminRisk
  # Builds a small, explainable profile of admin / risk controls exposed by a
  # verified contract. The first version is intentionally heuristic and ABI-led:
  # it answers "what privileged powers are detectable here?" without assigning
  # a subjective risk score.
  class Profiler
    CACHE_TTL = 60.seconds
    CACHE_VERSION = "v1"

    Result = Struct.new(:contract, :chain, :summary, :risk_flags, :controls,
                        :recent_governance, :evidence, :warnings,
                        :block_number, :fetched_at, :error,
                        keyword_init: true) do
      def success?
        error.blank?
      end

      def controls_detected?
        risk_flags.any? || controls.any?
      end
    end

    READABLE_CONTROLS = [
      { name: "paused",          key: "paused",          label: "Paused",          type: "bool" },
      { name: "deprecated",      key: "deprecated",      label: "Deprecated",      type: "bool" },
      { name: "owner",           key: "owner",           label: "Owner",           type: "address" },
      { name: "admin",           key: "admin",           label: "Admin",           type: "address" },
      { name: "implementation",  key: "implementation",  label: "Implementation",  type: "address" },
      { name: "masterMinter",    key: "master_minter",   label: "Master minter",   type: "address" },
      { name: "pauser",          key: "pauser",          label: "Pauser",          type: "address" },
      { name: "blacklister",     key: "blacklister",     label: "Blacklister",     type: "address" },
      { name: "rescuer",         key: "rescuer",         label: "Rescuer",         type: "address" },
      { name: "upgradedAddress", key: "upgraded_address", label: "Upgraded to",     type: "address" }
    ].freeze

    CAPABILITIES = {
      "upgradeable" => {
        functions: %w[implementation getImplementation upgradeTo upgradeToAndCall changeAdmin admin],
        events: %w[Upgraded AdminChanged]
      },
      "mintable" => {
        functions: %w[mint configureMinter removeMinter masterMinter minterAllowance isMinter setMinter],
        events: %w[Mint MinterConfigured MinterRemoved MasterMinterChanged MinterAdded MinterChanged]
      },
      "pausable" => {
        functions: %w[pause unpause paused pauser],
        events: %w[Pause Unpause Paused Unpaused PauserChanged]
      },
      "blacklistable" => {
        functions: %w[blacklist unBlacklist isBlacklisted blacklister],
        events: %w[Blacklisted UnBlacklisted BlacklisterChanged]
      },
      "freezable" => {
        functions: %w[freeze unfreeze isFrozen],
        events: %w[Frozen Unfrozen Freeze Unfreeze]
      },
      "ownable" => {
        functions: %w[owner transferOwnership acceptOwnership pendingOwner],
        events: %w[OwnershipTransferred OwnershipTransferStarted]
      },
      "role_based" => {
        functions: %w[hasRole getRoleAdmin grantRole revokeRole renounceRole DEFAULT_ADMIN_ROLE],
        events: %w[RoleGranted RoleRevoked RoleAdminChanged]
      }
    }.freeze

    def self.call(contract:)
      new(contract).call
    end

    def initialize(contract)
      @contract = contract
      @chain = contract.chain
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build_profile }
    end

    private

    def build_profile
      flags, evidence = detect_capabilities
      controls, block_number = read_controls
      recent_governance = build_recent_governance

      Result.new(
        contract: @contract.address,
        chain: @chain.slug,
        summary: summarize(flags),
        risk_flags: flags,
        controls: controls,
        recent_governance: recent_governance,
        evidence: evidence,
        warnings: warnings_for(flags, controls),
        block_number: block_number,
        fetched_at: Time.current,
        error: nil
      )
    rescue StandardError => e
      Rails.logger.warn("[AdminRisk::Profiler] failed: #{e.class}: #{e.message}")
      Result.new(
        contract: @contract.address,
        chain: @chain.slug,
        summary: "Could not build admin risk profile.",
        risk_flags: [],
        controls: [],
        recent_governance: build_recent_governance,
        evidence: [],
        warnings: [],
        block_number: nil,
        fetched_at: Time.current,
        error: e.message
      )
    end

    def detect_capabilities
      fn_names = Array(@contract.abi).filter_map { |item| item["name"] if item["type"] == "function" }.to_set
      event_names = @contract.events.filter_map { |event| event["name"] }.to_set

      evidence = []
      flags = CAPABILITIES.filter_map do |flag, spec|
        matched_functions = spec[:functions] & fn_names.to_a
        matched_events = spec[:events] & event_names.to_a
        proxy_detected = flag == "upgradeable" && @contract.implementation_address.present?

        next unless matched_functions.any? || matched_events.any? || proxy_detected

        evidence.concat(matched_functions.map { |name| { type: "function", name: name, flag: flag } })
        evidence.concat(matched_events.map { |name| { type: "event", name: name, flag: flag } })
        evidence << { type: "proxy", name: "implementation", flag: flag } if proxy_detected
        flag
      end

      [ flags, evidence ]
    end

    def read_controls
      specs = READABLE_CONTROLS.filter_map { |spec| control_function_for(spec) }
      controls = []

      if @contract.implementation_address.present? && specs.none? { |spec| spec[:key] == "implementation" }
        controls << {
          key: "implementation",
          label: "Implementation",
          type: "address",
          value: @contract.implementation_address,
          source: "proxy"
        }
      end

      return [ controls, nil ] if specs.empty?

      calls = specs.map do |spec|
        ChainReader::Multicall3Client::Call.new(target: @contract.address, function: spec[:abi])
      end
      batch = ChainReader::Multicall3Client.call(chain: @chain, calls: calls)

      controls.concat(specs.zip(batch.results).filter_map { |spec, result| control_payload(spec, result) })
      [ controls, batch.block_number ]
    rescue StandardError => e
      Rails.logger.warn("[AdminRisk::Profiler] control read failed: #{e.class}: #{e.message}")
      [ controls, nil ]
    end

    def control_function_for(spec)
      fn = Array(@contract.abi).find do |item|
        item["type"] == "function" &&
          item["name"] == spec[:name] &&
          item["stateMutability"].in?(%w[view pure]) &&
          Array(item["inputs"]).empty? &&
          Array(item["outputs"]).length == 1 &&
          item["outputs"].first["type"] == spec[:type]
      end
      return nil unless fn

      spec.merge(abi: fn)
    end

    def control_payload(spec, result)
      return nil unless result&.success && result.values.present?

      {
        key: spec[:key],
        label: spec[:label],
        type: spec[:type],
        value: result.values.first,
        source: "view"
      }
    end

    def build_recent_governance
      latest = @contract.governance_events.newest_first.first
      {
        count: @contract.governance_events.count,
        latest_event: latest&.event_name,
        latest_category: latest&.category,
        latest_block: latest&.block_number
      }
    end

    def summarize(flags)
      return "No admin risk controls detected from the verified ABI." if flags.empty?

      "Detected #{human_join(flags.map { |flag| flag.tr('_', ' ') })} controls from the verified ABI."
    end

    def warnings_for(flags, controls)
      warnings = []
      warnings << "Upgradeability inferred from ABI/events; proxy storage resolution may be incomplete." if flags.include?("upgradeable") && controls.none? { |c| c[:key] == "implementation" }
      warnings
    end

    def human_join(words)
      return words.first.to_s if words.length == 1
      return words.join(" and ") if words.length == 2

      "#{words[0...-1].join(', ')}, and #{words.last}"
    end

    def cache_key
      "admin_risk:#{CACHE_VERSION}:#{@chain.slug}:#{@contract.address}"
    end
  end
end
