# frozen_string_literal: true

module Polymarket
  # Aggregates OrderFilled events from a Polymarket CTFExchange or
  # NegRiskCtfExchange. Trades go USDC-leg <-> outcome-token-leg: one of
  # makerAssetId/takerAssetId is 0 (USDC) and the other is a CTF positionId.
  # Price = USDC_amount / outcome_token_amount (both in their raw 6-decimal
  # units), so price has 6/6 = no decimal adjustment needed beyond
  # BigDecimal arithmetic.
  #
  # Window: ContractEvents::RecentFetcher pulls the last 5000 blocks
  # (~3h on Polygon at 2s/block). We surface that as "last ~3h" rather than
  # extrapolating to 24h.
  class ExchangeActivity
    EVENT_NAME = "OrderFilled"
    RECENT_FILL_LIMIT = 8
    TOP_MARKETS_LIMIT = 5
    USDC_DECIMALS = 6

    Fill = Struct.new(
      :tx_hash, :block_number, :timestamp,
      :token_id, :market_label, :slug, :side,
      :usdc_amount, :outcome_amount, :price,
      :taker, :maker,
      keyword_init: true
    )

    MarketAggregate = Struct.new(
      :token_id, :market_label, :slug, :outcome,
      :fills_count, :volume_usdc,
      keyword_init: true
    )

    def self.call(contract:)
      new(contract: contract).call
    end

    def initialize(contract:)
      @contract = contract
    end

    def call
      result = ContractEvents::RecentFetcher.call(
        contract: @contract,
        event_name: EVENT_NAME,
        limit: ContractEvents::RecentFetcher::MAX_LIMIT
      )

      return error_payload(result.error) unless result.success?

      token_index = PolymarketClient.fetch_token_id_index
      fills = result.events.filter_map { |event| build_fill(event, token_index) }

      {
        ok: true,
        window_block_from: result.from_block,
        window_block_to: result.latest_block,
        fills_count: fills.size,
        volume_usdc: fills.sum(BigDecimal("0")) { |fill| fill.usdc_amount || BigDecimal("0") },
        unique_takers: fills.map(&:taker).compact.uniq.size,
        unique_markets: fills.map(&:token_id).compact.uniq.size,
        top_markets: aggregate_by_market(fills).first(TOP_MARKETS_LIMIT),
        latest_fills: fills.first(RECENT_FILL_LIMIT),
        fetched_at: Time.current
      }
    end

    private

    def build_fill(event, token_index)
      return nil unless event.args.is_a?(Hash)

      decoded = decode_v2(event.args) || decode_v1(event.args)
      return nil unless decoded

      token_id, side, usdc_raw, outcome_raw = decoded
      return nil if outcome_raw.nil? || outcome_raw.zero?

      ref = token_index[token_id]
      usdc_amount = usdc_raw / BigDecimal(10**USDC_DECIMALS)
      price = (BigDecimal(usdc_raw) / BigDecimal(outcome_raw)).round(4)

      Fill.new(
        tx_hash: event.tx_hash,
        block_number: event.block_number,
        timestamp: event.timestamp,
        token_id: token_id,
        market_label: market_label_for(ref, side),
        slug: ref&.slug,
        side: side,
        usdc_amount: usdc_amount,
        outcome_amount: BigDecimal(outcome_raw) / BigDecimal(10**USDC_DECIMALS),
        price: price,
        taker: event.args["taker"],
        maker: event.args["maker"]
      )
    end

    # V2 CTFExchange / NegRiskCtfExchange V2:
    #   OrderFilled(orderHash, maker, taker, uint8 side, uint256 tokenId,
    #               uint256 makerAmountFilled, uint256 takerAmountFilled,
    #               uint256 fee, bytes32 builder, bytes32 metadata)
    # `side` is the *maker's* order side: 0=BUY (maker bought outcome,
    # paid USDC), 1=SELL (maker sold outcome, received USDC). The label
    # mirrors V1: "Buy" means the outcome was bought (maker pov).
    def decode_v2(args)
      return nil unless args.key?("tokenId") && args.key?("side")

      token_id = to_big(args["tokenId"])
      side_raw = to_big(args["side"])
      maker_amt = to_big(args["makerAmountFilled"])
      taker_amt = to_big(args["takerAmountFilled"])
      return nil unless token_id && side_raw && maker_amt && taker_amt

      if side_raw.zero?
        usdc_raw = maker_amt
        outcome_raw = taker_amt
        label = "Buy"
      else
        usdc_raw = taker_amt
        outcome_raw = maker_amt
        label = "Sell"
      end

      [ token_id.to_i.to_s, label, usdc_raw, outcome_raw ]
    end

    # V1 CTFExchange / NegRiskCtfExchange V1:
    #   OrderFilled(orderHash, maker, taker, uint256 makerAssetId,
    #               uint256 takerAssetId, uint256 makerAmountFilled,
    #               uint256 takerAmountFilled, uint256 fee)
    # One side has assetId=0 (USDC collateral); the other is the CTF
    # positionId. Both maker and taker are paired explicitly.
    def decode_v1(args)
      return nil unless args.key?("makerAssetId") && args.key?("takerAssetId")

      maker_id = to_big(args["makerAssetId"])
      taker_id = to_big(args["takerAssetId"])
      maker_amt = to_big(args["makerAmountFilled"])
      taker_amt = to_big(args["takerAmountFilled"])
      return nil unless maker_id && taker_id && maker_amt && taker_amt

      if maker_id.zero? && !taker_id.zero?
        [ taker_id.to_i.to_s, "Buy", maker_amt, taker_amt ]
      elsif taker_id.zero? && !maker_id.zero?
        [ maker_id.to_i.to_s, "Sell", taker_amt, maker_amt ]
      end
    end

    def market_label_for(ref, side)
      return "Unknown market" unless ref

      base = ref.question.presence || ref.slug.presence || "Polymarket market"
      outcome = ref.outcome.presence
      outcome ? "#{base} · #{outcome}" : base
    end

    def aggregate_by_market(fills)
      fills.group_by(&:token_id).map do |token_id, group|
        first = group.first
        MarketAggregate.new(
          token_id: token_id,
          market_label: first.market_label,
          slug: first.slug,
          outcome: nil,
          fills_count: group.size,
          volume_usdc: group.sum(BigDecimal("0")) { |fill| fill.usdc_amount || BigDecimal("0") }
        )
      end.sort_by { |agg| -agg.volume_usdc }
    end

    def to_big(value)
      return nil if value.nil?
      return BigDecimal(value.to_s) if value.is_a?(Integer)

      str = value.to_s
      return nil if str.empty?

      if str.start_with?("0x", "0X")
        BigDecimal(str.sub(/\A0x/i, "").to_i(16).to_s)
      else
        BigDecimal(str)
      end
    rescue ArgumentError
      nil
    end

    def error_payload(message)
      {
        ok: false,
        error: message,
        fetched_at: Time.current
      }
    end
  end
end
