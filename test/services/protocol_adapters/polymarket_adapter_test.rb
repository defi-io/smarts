require "test_helper"

class ProtocolAdapters::PolymarketAdapterTest < ActiveSupport::TestCase
  PUSD = "0xc011a7e12a19f7b1f670d46f03b03f3342e82dfb"
  POLYMARKET_CTF = "0x4d97dcd97ec945f40cf65f87097ace5ea0476045"
  POLYMARKET_EXCHANGE = "0xe111180000d2663c0091e4f400237545b87b996b"
  POLYMARKET_NEG_RISK_EXCHANGE = "0xe2222d279d744050d28e00520010520000310f59"
  COLLATERAL_ADAPTER = "0xada100874d00e3331d00f2007a9c336a65009718"
  NEG_RISK_COLLATERAL_ADAPTER = "0xada200001000ef00d07553cee7006808f895c6f1"
  NEG_RISK_OPERATOR = "0x71523d0f655b41e805cec45b17163f528b59b820"
  UMA_ADAPTER = "0x2f5e3684cb1f318ec51b00edba38d79ac2c0aa9d"
  NEG_RISK_ADAPTER = "0xd91e80cf2e7be2e162c6513ced06f1dd0da35296"

  setup do
    @polygon = chains(:polygon)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "matches every curated Polymarket address on Polygon" do
    addresses = ContractSlugs.polymarket_slugs.map { |slug| ContractSlugs.resolve(slug).last }
    assert_equal addresses.sort, ProtocolAdapters::PolymarketAdapter::ADDRESSES.to_a.sort

    addresses.each do |address|
      contract = Contract.new(chain: @polygon, address: address)
      assert ProtocolAdapters::PolymarketAdapter.matches?(contract), "expected #{address} to match"
    end
  end

  test "does not match the same address on another chain" do
    contract = Contract.new(chain: chains(:ethereum), address: POLYMARKET_CTF)
    refute ProtocolAdapters::PolymarketAdapter.matches?(contract)
  end

  test "is registered before RPC-backed Uniswap detection" do
    assert_operator ProtocolAdapters::Base::ADAPTER_NAMES.index("PolymarketAdapter"),
                    :<,
                    ProtocolAdapters::Base::ADAPTER_NAMES.index("UniswapV3Adapter")
  end

  test "role controls display_name and template partial" do
    ctf = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_CTF))
    pusd = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: PUSD))
    exchange = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_EXCHANGE))
    neg_exchange = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_NEG_RISK_EXCHANGE))
    uma = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: UMA_ADAPTER))
    neg = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: NEG_RISK_ADAPTER))
    collateral = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: COLLATERAL_ADAPTER))
    neg_collateral = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: NEG_RISK_COLLATERAL_ADAPTER))
    operator = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: NEG_RISK_OPERATOR))

    assert_equal :pusd, pusd.role
    assert_equal "Polymarket pUSD", pusd.display_name
    assert_equal "protocol_adapters/polymarket_static", pusd.template_partial
    assert_equal :ctf, ctf.role
    assert_equal "protocol_adapters/polymarket_ctf", ctf.template_partial
    assert_equal :ctf_exchange, exchange.role
    assert_equal "Polymarket CTF Exchange", exchange.display_name
    assert_equal "protocol_adapters/polymarket_exchange", exchange.template_partial
    assert_equal "Binary market order matching · CTF outcome tokens · Polygon", exchange.exchange_description
    assert_match "binary Polymarket markets", exchange.architecture_summary
    assert_includes exchange.architecture_flow, "CTF Exchange"
    assert_equal "Binary / Yes-No markets", exchange.exchange_comparison[:market_type]
    assert_equal "polymarket-neg-risk-exchange-v2-polygon", exchange.exchange_comparison[:paired_slug]
    assert_equal :neg_risk_exchange, neg_exchange.role
    assert_equal "Polymarket Neg-Risk Exchange", neg_exchange.display_name
    assert_equal "protocol_adapters/polymarket_exchange", neg_exchange.template_partial
    assert_equal "Multi-outcome order matching · neg-risk outcome tokens · Polygon", neg_exchange.exchange_description
    assert_match "multi-outcome Polymarket markets", neg_exchange.architecture_summary
    assert_includes neg_exchange.architecture_flow, "Neg-Risk Exchange"
    assert_equal "Multi-outcome / mutually exclusive markets", neg_exchange.exchange_comparison[:market_type]
    assert_equal "polymarket-ctf-exchange-v2-polygon", neg_exchange.exchange_comparison[:paired_slug]
    assert_equal :uma_adapter, uma.role
    assert_equal "protocol_adapters/polymarket_uma_adapter", uma.template_partial
    assert_equal :neg_risk_adapter, neg.role
    assert_equal "protocol_adapters/polymarket_neg_risk_adapter", neg.template_partial
    assert_equal :collateral_adapter, collateral.role
    assert_equal "Polymarket Collateral Adapter", collateral.display_name
    assert_equal "protocol_adapters/polymarket_static", collateral.template_partial
    assert_equal :neg_risk_collateral_adapter, neg_collateral.role
    assert_equal "Polymarket Neg-Risk Collateral Adapter", neg_collateral.display_name
    assert_equal :neg_risk_operator, operator.role
    assert_equal "Polymarket Neg-Risk Operator", operator.display_name
    assert_match "resolution interface", operator.architecture_summary
  end

  test "panel_data routes exchange roles to ExchangeActivity and caches" do
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_EXCHANGE))
    payload = { ok: true, fills_count: 7, volume_usdc: BigDecimal("123"), top_markets: [], latest_fills: [], fetched_at: Time.current }
    calls = 0

    stub_class_method(Polymarket::ExchangeActivity, :call, ->(contract:) { calls += 1; payload }) do
      assert_equal 7, adapter.panel_data[:fills_count]
      assert_equal 7, adapter.panel_data[:fills_count]
      assert_equal 1, calls, "second call should hit the 30s panel cache"
    end
  end

  test "panel_data routes neg-risk exchange role to ExchangeActivity" do
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_NEG_RISK_EXCHANGE))
    payload = { ok: true, fills_count: 3, volume_usdc: BigDecimal("456"), top_markets: [], latest_fills: [], fetched_at: Time.current }

    stub_class_method(Polymarket::ExchangeActivity, :call, ->(contract:) {
      assert_equal POLYMARKET_NEG_RISK_EXCHANGE, contract.address
      payload
    }) do
      assert_equal 3, adapter.panel_data[:fills_count]
    end
  end

  test "panel_data routes ctf role to CtfActivity" do
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_CTF))
    payload = { ok: true, resolutions: [], preparations: [], redemptions: [], errors: {}, fetched_at: Time.current }

    stub_class_method(Polymarket::CtfActivity, :call, ->(contract:) { payload }) do
      assert_equal [], adapter.panel_data[:resolutions]
    end
  end

  test "panel_data routes uma_adapter role to UmaActivity" do
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: UMA_ADAPTER))
    payload = { ok: true, resolved: [], initialized: [], disputed: [], errors: {}, fetched_at: Time.current }

    stub_class_method(Polymarket::UmaActivity, :call, ->(contract:) { payload }) do
      assert_equal [], adapter.panel_data[:resolved]
    end
  end

  test "panel_data routes neg_risk_adapter role to NegRiskActivity" do
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: NEG_RISK_ADAPTER))
    payload = { ok: true, groups: {}, empty: true, unavailable_events: {}, fetched_at: Time.current }

    stub_class_method(Polymarket::NegRiskActivity, :call, ->(contract:) { payload }) do
      assert adapter.panel_data[:empty]
    end
  end

  test "panel_data for static architecture roles does not fetch live activity" do
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: NEG_RISK_OPERATOR))

    assert adapter.panel_data[:static]
  end

  test "exchange html partial renders activity stats and uses the polling frame" do
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_EXCHANGE))
    payload = {
      ok: true,
      window_block_to: 70_000_000,
      fills_count: 42,
      volume_usdc: BigDecimal("12345"),
      unique_takers: 18,
      unique_markets: 9,
      top_markets: [
        Polymarket::ExchangeActivity::MarketAggregate.new(
          token_id: "111", market_label: "Will BTC top $200k?", slug: "btc-200k", outcome: "Yes",
          fills_count: 12, volume_usdc: BigDecimal("8000")
        )
      ],
      latest_fills: [
        Polymarket::ExchangeActivity::Fill.new(
          tx_hash: "0xabc", block_number: 70_000_000, timestamp: 1.minute.ago.utc.iso8601,
          token_id: "111", market_label: "Will BTC top $200k?", slug: "btc-200k", side: "Buy",
          usdc_amount: BigDecimal("125.50"), outcome_amount: BigDecimal("170"),
          price: BigDecimal("0.7382"), taker: "0xtaker", maker: "0xmaker"
        )
      ],
      fetched_at: Time.current
    }

    stub_class_method(Polymarket::ExchangeActivity, :call, ->(contract:) { payload }) do
      html = ApplicationController.render(
        partial: "protocol_adapters/polymarket_exchange",
        locals: { adapter: adapter }
      )

      assert_includes html, 'id="polymarket_panel"'
      assert_includes html, 'data-controller="polymarket-prices-poll"'
      assert_includes html, "Polymarket CTF Exchange"
      assert_includes html, "Binary market order matching"
      assert_includes html, "42"
      assert_includes html, "12,345"
      assert_includes html, "Will BTC top $200k?"
      assert_includes html, "0.7382"
    end
  end

  test "exchange html partial distinguishes neg-risk exchange copy" do
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_NEG_RISK_EXCHANGE))
    payload = {
      ok: true,
      window_block_to: 70_000_000,
      fills_count: 0,
      volume_usdc: BigDecimal("0"),
      unique_takers: 0,
      unique_markets: 0,
      top_markets: [],
      latest_fills: [],
      fetched_at: Time.current
    }

    stub_class_method(Polymarket::ExchangeActivity, :call, ->(contract:) { payload }) do
      html = ApplicationController.render(
        partial: "protocol_adapters/polymarket_exchange",
        locals: { adapter: adapter }
      )

      assert_includes html, "Polymarket Neg-Risk Exchange"
      assert_includes html, "Multi-outcome order matching"
      refute_includes html, "Polymarket CTF Exchange"
    end
  end

  test "exchange html partial degrades to an error alert" do
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_EXCHANGE))
    payload = { ok: false, error: "etherscan 502", fetched_at: Time.current }

    stub_class_method(Polymarket::ExchangeActivity, :call, ->(contract:) { payload }) do
      html = ApplicationController.render(
        partial: "protocol_adapters/polymarket_exchange",
        locals: { adapter: adapter }
      )

      assert_includes html, "Could not read on-chain activity"
      assert_includes html, "etherscan 502"
    end
  end
end
