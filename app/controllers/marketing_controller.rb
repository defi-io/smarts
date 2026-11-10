require "set"

class MarketingController < ApplicationController
  allow_unauthenticated_access

  # Curated showcase for the landing page. A flat list grouped by category in
  # display order. Static on purpose: curation is the product thesis, and
  # "trending" lists would pollute the blue-chip signal with short-lived
  # memecoins we don't document well. Edit this list directly to change what
  # the landing page features.
  FEATURED = [
    # Stablecoins
    { category: "Stablecoins", chain: "eth", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC", name: "USD Coin",  blurb: "Circle's regulated USD stablecoin — largest by market cap." },
    { category: "Stablecoins", chain: "eth", address: "0xdac17f958d2ee523a2206206994597c13d831ec7",
      symbol: "USDT", name: "Tether USD", blurb: "The oldest and most-traded dollar stablecoin." },
    { category: "Stablecoins", chain: "eth", address: "0x6b175474e89094c44da98b954eedeac495271d0f",
      symbol: "DAI",  name: "Dai",        blurb: "MakerDAO's decentralized, crypto-backed stablecoin." },

    # DEX & Wrapped
    # Symbol holds the pair (the distinguishing identifier across many pools);
    # name carries the protocol + fee context. Matches the contract page H1
    # "USDC/WETH 0.05%" so cards and detail pages read the same.
    { category: "DEX & Wrapped", chain: "eth", address: "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640",
      symbol: "USDC/WETH", name: "Uniswap V3 · 0.05% fee", blurb: "Ethereum's deepest Uniswap V3 pool." },
    { category: "DEX & Wrapped", chain: "eth", address: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
      symbol: "WETH", name: "Wrapped Ether", blurb: "The ERC-20 form of ETH — plumbing for every DEX." },
    { category: "DEX & Wrapped", chain: "eth", address: "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
      symbol: "WBTC", name: "Wrapped Bitcoin", blurb: "BitGo-custodied Bitcoin, bridged as an ERC-20." },

    # Governance / Top tokens
    { category: "Governance", chain: "eth", address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
      symbol: "UNI",  name: "Uniswap",   blurb: "Governance token for the Uniswap protocol." },
    { category: "Governance", chain: "eth", address: "0x514910771af9ca656af840dff83e8264ecf986ca",
      symbol: "LINK", name: "Chainlink", blurb: "Token for Chainlink's decentralized oracle network." },
    { category: "Governance", chain: "eth", address: "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9",
      symbol: "AAVE", name: "Aave",      blurb: "Governance and safety-module token for Aave." },

    # Multi-chain demo
    { category: "Multi-chain", chain: "base",     address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      symbol: "USDC", name: "USD Coin (Base)",     blurb: "Native Circle-issued USDC on Base." },
    { category: "Multi-chain", chain: "arbitrum", address: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
      symbol: "USDC", name: "USD Coin (Arbitrum)", blurb: "Native Circle-issued USDC on Arbitrum One." },
    { category: "Multi-chain", chain: "bnb",      address: "0x55d398326f99059ff775485246999027b3197955",
      symbol: "USDT", name: "Tether USD (BNB)",    blurb: "The most-traded dollar stablecoin on BNB Smart Chain." },
    { category: "Multi-chain", chain: "bnb",      address: "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c",
      symbol: "WBNB", name: "Wrapped BNB",         blurb: "The canonical wrapped gas token on BNB Smart Chain." },
    { category: "Multi-chain", chain: "bnb",      address: "0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82",
      symbol: "CAKE", name: "PancakeSwap",         blurb: "The flagship DEX token for BNB Smart Chain's biggest venue." },
    # Polygon rebranded MATIC → POL in 2024 and updated this contract's on-chain
    # name()/symbol() accordingly. Card now matches on-chain truth; blurb
    # preserves the WMATIC tie-in for users arriving on legacy mental models.
    { category: "Multi-chain", chain: "polygon",  address: "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270",
      symbol: "WPOL", name: "Wrapped POL",          blurb: "Polygon's canonical wrapped gas token (formerly WMATIC)." }
  ].freeze

  # Tools exposed over MCP. Kept in sync with app/tools/*.
  MCP_TOOLS = [
    { name: "get_contract_info",    blurb: "Metadata about a verified contract: name, classification, adapter, function counts." },
    { name: "get_contract_source",  blurb: "Fetch the verified Solidity source: file index, single-file content, or substring grep across files." },
    { name: "get_admin_risk",       blurb: "Current admin / risk profile for a verified contract: detected controls, current values, and warnings." },
    { name: "get_aave_v3_market",   blurb: "Live Aave V3 market: per-asset supply/borrow APY, supplied and borrowed in USD, utilization, LTV, caps, frozen/paused." },
    { name: "get_erc20_info",       blurb: "Live token state: formatted supply, price, market cap, issuer, admin controls (paused/owner/minter/…)." },
    { name: "get_polymarket_market", blurb: "Polymarket market state by slug or condition ID: outcomes, prices when present, resolution payouts, and CTF position IDs." },
    { name: "get_polymarket_position", blurb: "Wallet balances for explicit Polymarket markets by condition ID or slug, including redeemable resolved outcomes." },
    { name: "get_polymarket_resolution", blurb: "Resolution audit for a Polymarket market: CTF payout vector from chain, Gamma closed/open status, outcome IDs, and consistency flags." },
    { name: "get_protocol_tvl",     blurb: "DefiLlama protocol TVL: total, 1d/7d change, borrowed, per-chain breakdown." },
    { name: "get_recent_events",    blurb: "Most recent events emitted by a contract, decoded against its ABI. Filter by event name; unknown topics return raw." },
    { name: "get_stablecoin_supply", blurb: "DefiLlama stablecoin supply: circulating, 1d/7d change, peg, price, per-chain breakdown." },
    { name: "get_uniswap_v3_pool",  blurb: "Live pool state: token pair, fee, both-direction price, liquidity, tick, TVL." },
    { name: "get_yield_pools",      blurb: "DefiLlama yield pools on supported chains, filtered by project / chain / token, with base and reward APY." },
    { name: "inspect_address",      blurb: "Classifies any address as EOA / contract / EIP-7702 wallet, plus balance, nonce, and reverse ENS." },
    { name: "list_article_drafts",  blurb: "Authenticated publishing workflow: list multilingual article drafts under docs/drafts." },
    { name: "publish_article",      blurb: "Authenticated publishing workflow: validate and publish a multilingual draft into article pages." },
    { name: "validate_article_draft", blurb: "Authenticated publishing workflow: validate one multilingual article draft without saving." },
    { name: "read_contract_state",  blurb: "Read any view/pure function by name, with positional args. Returns decoded output." }
  ].freeze

  MCP_EXAMPLE_QUERIES = [
    { q: "Is USDC paused right now?",                           tool: "get_erc20_info" },
    { q: "What's the TVL of the Uniswap V3 USDC/WETH 0.05% pool?", tool: "get_uniswap_v3_pool" },
    { q: "What's the USDC supply APY on Aave V3 Base right now?", tool: "get_aave_v3_market" },
    { q: "How much USDC circulates on Base?",                  tool: "get_stablecoin_supply" },
    { q: "What are the best USDC yields on Arbitrum above $10M TVL?", tool: "get_yield_pools" },
    { q: "Who is 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045?",  tool: "inspect_address" },
    { q: "Get the total supply of USDT on Arbitrum.",           tool: "get_erc20_info" },
    { q: "Who can blacklist my USDC balance?",                  tool: "get_erc20_info" },
    { q: "Show me the current admin risk profile for USDC.",    tool: "get_admin_risk" },
    { q: "Show me where USDC's blacklisting logic lives in source.", tool: "get_contract_source" },
    { q: "Show me the last 10 swaps on the USDC/WETH 0.05% pool.", tool: "get_recent_events" },
    { q: "Who can pause or upgrade Polymarket's CTF Exchange V2?", tool: "get_admin_risk" },
    { q: "What does Polymarket think about this market by slug?", tool: "get_polymarket_market" },
    { q: "Audit how this Polymarket market resolved on-chain.", tool: "get_polymarket_resolution" },
    { q: "Call balanceOf(0xabc…) on USDC.",                     tool: "read_contract_state" }
  ].freeze

  MCP_SHORTCUTS = [
    { slug: "usdc-eth", blurb: "Ethereum USDC — stablecoin admin controls and blacklist surface." },
    { slug: "usdt-arbitrum", blurb: "Arbitrum USDT — multi-chain stablecoin lookup." },
    { slug: "univ3-usdc-weth-eth", blurb: "Deep Uniswap V3 USDC/WETH pool on Ethereum." },
    { slug: "aavev3-pool-base", blurb: "Aave V3 Pool proxy on Base." },
    { slug: "univ3-factory-eth", blurb: "Canonical Uniswap V3 factory on Ethereum." },
    { slug: "polymarket-ctf-exchange-v2-polygon", blurb: "Polymarket binary market exchange — admin and pause surface." },
    { slug: "polymarket-neg-risk-exchange-v2-polygon", blurb: "Polymarket neg-risk exchange — multi-outcome admin surface." },
    { slug: "polymarket-uma-adapter-v3-polygon", blurb: "Polymarket UMA adapter — resolution and dispute governance." }
  ].freeze

  def home
    if params[:q].present? && params[:q].match?(%r{\A[a-z]+/0x[0-9a-fA-F]{40}\z})
      chain_slug, address = params[:q].split("/", 2)
      slug = ContractSlugResolver.for(chain_slug, address)
      target =
        if slug.present?
          helpers.localized_contract_path(locale: I18n.locale, slug: slug)
        else
          helpers.localized_contract_path(locale: I18n.locale, chain_slug: chain_slug, address: address)
        end

      redirect_to target, status: :moved_permanently
      return
    end

    @homepage = Marketing::HomepagePresenter.call(featured: FEATURED, recent_limit: 3, contract_limit: 50, locale: I18n.locale)
    response.set_header("Vary", "Accept-Language, Cookie")
    expires_in 6.hours, public: true
  end

  def sitemap
    @sitemap = Marketing::SitemapBuilder.call(contract_limit: 50)
    expires_in 12.hours, public: true
  end

  def robots
    response.set_header("Cache-Control", "public, max-age=3600")

    render plain: <<~TXT
      User-agent: *
      Allow: /
      Sitemap: #{SeoHelper::SITE_URL}/sitemap.xml
    TXT
  end

  def mcp_docs
    @endpoint_url   = mcp_endpoint_url
    @tools          = MCP_TOOLS
    @example_queries = MCP_EXAMPLE_QUERIES
    @shortcuts      = MCP_SHORTCUTS
    response.set_header("Vary", "Accept-Language, Cookie")
    expires_in 12.hours, public: true
  end

  # Forward-looking discovery manifest. MCP spec hasn't formalized a
  # well-known path yet (2026-04), but publishing it now is cheap,
  # self-documenting, and front-loads us for whatever standard emerges.
  def polymarket
    @markets = PolymarketClient.fetch_top_markets(limit: 10)
    @prices = fetch_live_prices(@markets)
    @disputed_slugs = fetch_disputed_slugs
  rescue PolymarketClient::Error => e
    @markets = []
    @prices = {}
    @disputed_slugs = Set.new
    flash.now[:alert] = "Could not load Polymarket data: #{e.message}"
  end

  def ai_plugin
    response.set_header("Cache-Control", "public, max-age=3600")
    response.set_header("Access-Control-Allow-Origin", "*")

    render json: {
      schema_version: "v1",
      name_for_human: "Smarts — Smart Contract Docs",
      name_for_model: "smarts",
      description_for_human: "Live docs for every verified smart contract. Query on-chain state, token info, and admin risk across Ethereum, Base, Arbitrum, Optimism, BNB, Polygon, Robinhood Chain, and Arc.",
      description_for_model: "Use the Smarts API to read live on-chain state for verified smart contracts on EVM chains (Ethereum, Base, Arbitrum, Optimism, BNB, Polygon, Robinhood Chain, Arc). You can look up ERC-20 token metadata and prices, Uniswap V3 pool state, Aave V3 lending markets, DefiLlama stablecoin supply, protocol TVL and yield pools, admin risk profiles, Polymarket markets, contract source code, and call any view function. Use curated slugs (e.g. 'usdc-eth', 'uni-eth') or chain+address pairs.",
      auth: { type: "none" },
      api: {
        type: "openapi",
        url: "https://smarts.md/api/openapi.json"
      },
      logo_url: "https://smarts.md/logo.png",
      contact_email: "bob@smarts.md",
      legal_info_url: "https://smarts.md/"
    }
  end

  def openapi_spec
    response.set_header("Cache-Control", "public, max-age=3600")
    response.set_header("Access-Control-Allow-Origin", "*")

    render json: build_openapi_spec
  end

  def well_known_mcp
    response.set_header("Cache-Control", "public, max-age=3600")
    response.set_header("Access-Control-Allow-Origin", "*")

    render json: {
      name: "smarts",
      version: "0.1.0",
      description: "Live docs for every verified smart contract. MCP access to on-chain state, prices, issuer, and admin controls.",
      homepage_url: "https://smarts.md/",
      documentation_url: "https://mcp.smarts.md/",
      protocol_version: "2025-03-26",
      transports: [
        {
          type: "streamable-http",
          endpoint: mcp_endpoint_url
        }
      ],
      capabilities: {
        tools: true,
        resources: false,
        prompts: false
      },
      tools: MCP_TOOLS.map { |t| { name: t[:name], description: t[:blurb] } }
    }
  end

  private

  # Generates the OpenAPI 3.1 spec from the same tool definitions used by
  # the MCP server. Each public tool becomes a GET endpoint at
  # /api/v1/:tool_name with query parameters derived from input_schema.
  def build_openapi_spec
    tools = Api::V1::ToolsController::TOOL_MAP

    paths = tools.each_with_object({}) do |(name, klass), h|
      schema = klass.input_schema_value.to_h
      properties = schema[:properties] || {}
      required = Array(schema[:required])

      parameters = properties.map do |pname, prop|
        param = {
          name: pname.to_s,
          in: "query",
          description: prop[:description].to_s,
          required: required.include?(pname.to_s),
          schema: { type: prop[:type] }
        }
        if param[:schema][:type] == "array"
          param[:schema][:items] = prop[:items] || { type: "string" }
          param[:style] = "form"
          param[:explode] = true
        end
        param
      end

      h["/api/v1/#{name}"] = {
        get: {
          operationId: name,
          summary: klass.description,
          parameters: parameters,
          responses: {
            "200" => {
              description: "Successful response",
              content: { "application/json" => { schema: { type: "object" } } }
            },
            "404" => { description: "Unknown tool or resource not found" },
            "422" => { description: "Unprocessable request" }
          }
        }
      }
    end

    {
      openapi: "3.1.0",
      info: {
        title: "Smarts API",
        version: "1.0.0",
        description: "Live docs for every verified smart contract. Query on-chain state, ERC-20 tokens, Uniswap V3 pools, admin risk, Polymarket markets, and more across Ethereum, Base, Arbitrum, Optimism, BNB, Polygon, Robinhood Chain, and Arc."
      },
      servers: [ { url: "https://smarts.md" } ],
      paths: paths
    }
  end

  def fetch_live_prices(markets)
    token_ids = markets.flat_map { |m| m.tokens.map(&:token_id) }.compact.uniq
    return {} if token_ids.empty?

    PolymarketClient.fetch_live_prices(token_ids)
  rescue PolymarketClient::Error => e
    Rails.logger.warn("[MarketingController] live prices failed: #{e.message}")
    {}
  end

  def fetch_disputed_slugs
    chain_slug, address = ContractSlugResolver.resolve("polymarket-uma-adapter-v3-polygon")
    contract = Contract.find_by(chain: Chain.find_by(slug: chain_slug), address: address)
    return Set.new unless contract

    disputed = Polymarket::UmaActivity.call(contract: contract)[:disputed]
    Set.new(Array(disputed).filter_map(&:slug))
  rescue StandardError => e
    Rails.logger.warn("[MarketingController] disputed Polymarket lookup failed: #{e.class}: #{e.message}")
    Set.new
  end
end
