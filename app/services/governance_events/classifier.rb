# frozen_string_literal: true

module GovernanceEvents
  # Decides whether an ABI event represents a governance/admin action and
  # produces a short human-readable summary for a decoded instance. Pure
  # heuristic; no I/O, no AI. Shared by the timeline fetcher, the contract
  # page Governance tab, and the get_governance_timeline MCP tool.
  class Classifier
    # Suffix-based detection covers most protocols that follow OpenZeppelin
    # conventions: *Changed (role updates), *Configured (parameter set),
    # *Removed (capability revoked), *Transferred (ownership), *Upgraded.
    GOVERNANCE_SUFFIXES = %w[Changed Configured Removed Transferred Upgraded].freeze

    # Exact matches for events that don't end in one of the suffixes above.
    GOVERNANCE_NAMES = %w[Pause Unpause AdminChanged Initialized].freeze

    # High-volume per-account risk actions. Worth tracking, but kept in a
    # separate category so the UI can fold them by default and keep the
    # timeline readable.
    RISK_ACTION_NAMES = %w[Blacklisted UnBlacklisted Frozen Unfrozen].freeze

    CATEGORY_ROLE_CHANGE = "role_change"
    CATEGORY_CONFIG      = "config"
    CATEGORY_UPGRADE     = "upgrade"
    CATEGORY_LIFECYCLE   = "lifecycle"
    CATEGORY_RISK_ACTION = "risk_action"

    class << self
      def governance?(event_abi)
        !category_for(event_abi).nil?
      end

      def filter(events_abi)
        events_abi.select { |event| governance?(event) }
      end

      def classify(events_abi)
        events_abi.filter_map do |event|
          category = category_for(event)
          next unless category

          { name: event["name"], category: category, abi: event }
        end
      end

      def category_for(event_abi)
        name = event_abi.is_a?(Hash) ? event_abi["name"] : nil
        return nil unless name.is_a?(String)

        return CATEGORY_RISK_ACTION if RISK_ACTION_NAMES.include?(name)
        return CATEGORY_UPGRADE     if %w[Upgraded AdminChanged].include?(name)
        return CATEGORY_LIFECYCLE   if %w[Pause Unpause Initialized].include?(name)
        return CATEGORY_ROLE_CHANGE if name == "OwnershipTransferred"

        return suffix_category(name) if GOVERNANCE_SUFFIXES.any? { |s| name.end_with?(s) }

        nil
      end

      def summarize(event_name, args)
        args = args.to_h if args.respond_to?(:to_h)
        args ||= {}

        case event_name
        when "OwnershipTransferred"
          "Owner: #{addr(args['previousOwner'])} → #{addr(args['newOwner'])}"
        when "MasterMinterChanged"
          "Master minter updated to #{addr(args['newMasterMinter'])}"
        when "PauserChanged"
          "Pauser updated to #{addr(args['newAddress'] || args['newPauser'])}"
        when "BlacklisterChanged"
          "Blacklister updated to #{addr(args['newBlacklister'])}"
        when "RescuerChanged"
          "Rescuer updated to #{addr(args['newRescuer'])}"
        when "MinterConfigured"
          "Minter #{addr(args['minter'])} allowance set to #{num(args['minterAllowedAmount'])}"
        when "MinterRemoved"
          "Minter #{addr(args['oldMinter'])} removed"
        when "Pause"
          "Contract paused"
        when "Unpause"
          "Contract unpaused"
        when "Blacklisted"
          "#{addr(args['_account'] || args['account'])} added to blacklist"
        when "UnBlacklisted"
          "#{addr(args['_account'] || args['account'])} removed from blacklist"
        when "Upgraded"
          "Implementation upgraded to #{addr(args['implementation'])}"
        when "AdminChanged"
          "Proxy admin: #{addr(args['previousAdmin'])} → #{addr(args['newAdmin'])}"
        when "Initialized"
          "Initialized (version #{args['version'] || '?'})"
        else
          generic_summary(event_name, args)
        end
      end

      private

      def suffix_category(name)
        return CATEGORY_ROLE_CHANGE if name.end_with?("Transferred")
        return CATEGORY_UPGRADE     if name.end_with?("Upgraded")

        CATEGORY_CONFIG
      end

      # Fallback summary for *Changed / *Configured / *Removed events we
      # haven't hand-templated. Pick out address-like and numeric args so the
      # output still tells the reader what changed.
      def generic_summary(name, args)
        parts = args.map do |key, value|
          formatted = case value
                      when nil then "—"
                      when String then address?(value) ? addr(value) : value
                      when Integer then num(value)
                      else value.to_s
                      end
          "#{key}=#{formatted}"
        end
        parts.any? ? "#{name}(#{parts.join(', ')})" : name
      end

      def addr(value)
        return "—" if value.nil?
        return value unless address?(value)

        "#{value[0, 6]}…#{value[-4..]}"
      end

      def address?(value)
        value.is_a?(String) && value.match?(/\A0x[0-9a-fA-F]{40}\z/)
      end

      def num(value)
        return "—" if value.nil?

        value.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
      end
    end
  end
end
