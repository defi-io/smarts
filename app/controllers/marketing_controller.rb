class MarketingController < ApplicationController
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
    { category: "DEX & Wrapped", chain: "eth", address: "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640",
      symbol: "V3 Pool", name: "Uniswap V3 USDC/WETH 0.05%", blurb: "Ethereum's deepest Uniswap V3 pool." },
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
    { category: "Multi-chain", chain: "polygon",  address: "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270",
      symbol: "WMATIC", name: "Wrapped MATIC",      blurb: "Polygon's canonical wrapped gas token." }
  ].freeze

  CHAIN_LABELS = {
    "eth" => "Ethereum", "base" => "Base", "arbitrum" => "Arbitrum", "optimism" => "Optimism", "polygon" => "Polygon"
  }.freeze

  MCP_ENDPOINT_URL = "https://smarts.md/mcp/sse".freeze

  # Tools exposed over MCP. Kept in sync with app/tools/*.
  MCP_TOOLS = [
    { name: "get_contract_info",    blurb: "Metadata about a verified contract: name, classification, adapter, function counts." },
    { name: "get_erc20_info",       blurb: "Live token state: formatted supply, price, market cap, issuer, admin controls (paused/owner/minter/…)." },
    { name: "get_uniswap_v3_pool",  blurb: "Live pool state: token pair, fee, both-direction price, liquidity, tick, TVL." },
    { name: "inspect_address",      blurb: "Classifies any address as EOA / contract / EIP-7702 wallet, plus balance, nonce, and reverse ENS." },
    { name: "read_contract_state",  blurb: "Read any view/pure function by name, with positional args. Returns decoded output." }
  ].freeze

  MCP_EXAMPLE_QUERIES = [
    { q: "Is USDC paused right now?",                           tool: "get_erc20_info" },
    { q: "What's the TVL of the Uniswap V3 USDC/WETH 0.05% pool?", tool: "get_uniswap_v3_pool" },
    { q: "Who is 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045?",  tool: "inspect_address" },
    { q: "Get the total supply of USDT on Arbitrum.",           tool: "get_erc20_info" },
    { q: "Who can blacklist my USDC balance?",                  tool: "get_erc20_info" },
    { q: "Call balanceOf(0xabc…) on USDC.",                     tool: "read_contract_state" }
  ].freeze

  def home
    if params[:q].present? && params[:q].match?(%r{\A[a-z]+/0x[0-9a-fA-F]{40}\z})
      redirect_to "/#{params[:q]}", status: :moved_permanently
    end

    @featured_groups = FEATURED.group_by { |f| f[:category] }
  end

  def mcp_docs
    @endpoint_url   = MCP_ENDPOINT_URL
    @tools          = MCP_TOOLS
    @example_queries = MCP_EXAMPLE_QUERIES
  end
end
