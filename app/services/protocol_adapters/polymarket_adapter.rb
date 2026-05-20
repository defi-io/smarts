# frozen_string_literal: true

require "set"

module ProtocolAdapters
  class PolymarketAdapter < Base
    ROLES_BY_ADDRESS = {
      "0xc011a7e12a19f7b1f670d46f03b03f3342e82dfb" => :pusd,
      "0x4bfb41d5b3570defd03c39a9a4d8de6bd8b8982e" => :ctf_exchange,
      "0xe111180000d2663c0091e4f400237545b87b996b" => :ctf_exchange,
      "0xc5d563a36ae78145c45a50134d48a1215220f80a" => :neg_risk_exchange,
      "0xe2222d279d744050d28e00520010520000310f59" => :neg_risk_exchange,
      "0xada100874d00e3331d00f2007a9c336a65009718" => :collateral_adapter,
      "0xada200001000ef00d07553cee7006808f895c6f1" => :neg_risk_collateral_adapter,
      "0xd91e80cf2e7be2e162c6513ced06f1dd0da35296" => :neg_risk_adapter,
      "0x71523d0f655b41e805cec45b17163f528b59b820" => :neg_risk_operator,
      "0x4d97dcd97ec945f40cf65f87097ace5ea0476045" => :ctf,
      "0x71392e133063cc0d16f40e1f9b60227404bc03f7" => :uma_adapter,
      "0x6a9d222616c90fca5754cd1333cfd9b7fb6a4f74" => :uma_adapter,
      "0x2f5e3684cb1f318ec51b00edba38d79ac2c0aa9d" => :uma_adapter
    }.freeze

    ADDRESSES = ROLES_BY_ADDRESS.keys.to_set.freeze

    def self.type_tag
      "polymarket"
    end

    def self.matches?(contract)
      contract.chain.slug == "polygon" && ADDRESSES.include?(contract.address.to_s.downcase)
    end

    def protocol_name
      "Polymarket"
    end

    def role
      ROLES_BY_ADDRESS.fetch(contract.address.downcase)
    end

    def display_name
      case role
      when :pusd
        "Polymarket pUSD"
      when :ctf_exchange
        "Polymarket CTF Exchange"
      when :neg_risk_exchange
        "Polymarket Neg-Risk Exchange"
      when :ctf
        "Polymarket Conditional Tokens"
      when :uma_adapter
        "Polymarket UMA Adapter"
      when :neg_risk_adapter
        "Polymarket Neg-Risk Adapter"
      when :collateral_adapter
        "Polymarket Collateral Adapter"
      when :neg_risk_collateral_adapter
        "Polymarket Neg-Risk Collateral Adapter"
      when :neg_risk_operator
        "Polymarket Neg-Risk Operator"
      end
    end

    def template_partial
      case role
      when :ctf_exchange, :neg_risk_exchange
        "protocol_adapters/polymarket_exchange"
      when :pusd, :collateral_adapter, :neg_risk_collateral_adapter, :neg_risk_operator
        "protocol_adapters/polymarket_static"
      else
        "protocol_adapters/polymarket_#{role}"
      end
    end

    def exchange_description
      case role
      when :ctf_exchange
        "Binary market order matching · CTF outcome tokens · Polygon"
      when :neg_risk_exchange
        "Multi-outcome order matching · neg-risk outcome tokens · Polygon"
      else
        nil
      end
    end

    def architecture_summary
      case role
      when :ctf_exchange
        "Matches orders for binary Polymarket markets. Filled orders move CTF outcome tokens backed by collateral through the standard Conditional Tokens path."
      when :neg_risk_exchange
        "Matches orders for multi-outcome Polymarket markets. Filled orders use neg-risk outcome tokens, then resolution flows through the Neg-Risk Adapter before final CTF-style settlement."
      when :ctf
        "Holds Polymarket outcome balances as ERC-1155 conditional tokens and stores the final payout vector for resolved conditions."
      when :uma_adapter
        "Connects Polymarket questions to UMA's optimistic oracle, including initialization, disputes, and final answers."
      when :neg_risk_adapter
        "Resolves multi-outcome markets by mapping each outcome into neg-risk questions and reporting the final result back to the market system."
      when :pusd
        "Polymarket's user-facing collateral token. It sits in front of the CTF collateral path and is bridged through adapter contracts for market settlement."
      when :collateral_adapter
        "Bridges Polymarket pUSD collateral into the standard Conditional Tokens path used by binary markets."
      when :neg_risk_collateral_adapter
        "Bridges Polymarket pUSD collateral into the neg-risk collateral path used by multi-outcome markets."
      when :neg_risk_operator
        "Lets the UMA adapter target the Neg-Risk Adapter's resolution interface, connecting oracle answers to multi-outcome settlement."
      end
    end

    def architecture_flow
      case role
      when :ctf_exchange
        [ "Trader order", "CTF Exchange", "Conditional Tokens", "UMA Adapter", "Final payout" ]
      when :neg_risk_exchange
        [ "Trader order", "Neg-Risk Exchange", "Neg-Risk Adapter", "UMA Adapter", "Final payout" ]
      when :ctf
        [ "Prepared condition", "Outcome ERC-1155 balances", "Resolution payout vector", "Redemption" ]
      when :uma_adapter
        [ "Question initialized", "Answer proposed", "Dispute window", "Question resolved", "CTF payout" ]
      when :neg_risk_adapter
        [ "Multi-outcome market", "Neg-risk question set", "Outcome reported", "Settlement" ]
      when :pusd
        [ "Trader collateral", "pUSD", "Collateral adapter", "Market positions" ]
      when :collateral_adapter
        [ "pUSD", "Collateral Adapter", "Conditional Tokens", "Binary market positions" ]
      when :neg_risk_collateral_adapter
        [ "pUSD", "Neg-Risk Collateral Adapter", "Neg-risk collateral", "Multi-outcome positions" ]
      when :neg_risk_operator
        [ "UMA answer", "Neg-Risk Operator", "Neg-Risk Adapter", "Multi-outcome settlement" ]
      else
        []
      end
    end

    def exchange_comparison
      case role
      when :ctf_exchange
        {
          same_abi_note: "Shares the same trading ABI as the Neg-Risk Exchange; the difference is the market path.",
          market_type: "Binary / Yes-No markets",
          token_path: "CTF outcome tokens",
          resolution_path: "Conditional Tokens + UMA Adapter",
          paired_label: "Polymarket Neg-Risk Exchange",
          paired_slug: "polymarket-neg-risk-exchange-v2-polygon"
        }
      when :neg_risk_exchange
        {
          same_abi_note: "Shares the same trading ABI as the CTF Exchange; the difference is the market path.",
          market_type: "Multi-outcome / mutually exclusive markets",
          token_path: "Neg-risk outcome tokens",
          resolution_path: "Neg-Risk Adapter + UMA Adapter",
          paired_label: "Polymarket CTF Exchange",
          paired_slug: "polymarket-ctf-exchange-v2-polygon"
        }
      end
    end

    # Routes to the role-specific activity service. Each service produces a
    # hash payload that its matching partial knows how to render. A 30s
    # Solid Cache layer here matches the Turbo Frame poll cadence — same
    # bytes go to multiple concurrent visitors without re-querying.
    def panel_data
      Rails.cache.fetch(cache_key, expires_in: 30.seconds) do
        case role
        when :ctf_exchange, :neg_risk_exchange
          Polymarket::ExchangeActivity.call(contract: contract)
        when :ctf
          Polymarket::CtfActivity.call(contract: contract)
        when :uma_adapter
          Polymarket::UmaActivity.call(contract: contract)
        when :neg_risk_adapter
          Polymarket::NegRiskActivity.call(contract: contract)
        when :pusd, :collateral_adapter, :neg_risk_collateral_adapter, :neg_risk_operator
          { ok: true, static: true, fetched_at: Time.current }
        end
      end
    end

    private

    def cache_key
      "protocol_panel:polymarket:v5:#{role}:#{chain.slug}:#{contract.address}"
    end
  end
end
