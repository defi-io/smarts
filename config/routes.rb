Rails.application.routes.draw do
  # ──────────────────────────────────────────────────────────────────────
  # MCP server (Streamable HTTP transport, MCP spec 2025-03-26).
  #
  # `MCP::Server::Transports::StreamableHTTPTransport` is a standard Rack
  # app that internally dispatches POST (client-to-server JSON-RPC),
  # GET (optional server-to-client SSE stream), and DELETE (session
  # termination) per the spec. Mounting at `/mcp` routes all those.
  #
  # `stateless: true` skips per-session memory state, which lets us run
  # Puma with workers > 0 and scale horizontally without sticky sessions.
  # We have no notification / progress / subscription needs — every tool
  # call is request/response — so statelessness is the right default.
  #
  # Tool classes are eagerly referenced here so Zeitwerk autoloads them
  # when routes are drawn; constructor takes the array directly.
  # ──────────────────────────────────────────────────────────────────────
  mcp_server = MCP::Server.new(
    name: "smarts",
    version: "0.1.0",
    instructions: "Live docs for verified smart contracts on Ethereum, Base, Arbitrum, Optimism, and Polygon. Use these tools to read on-chain state, ERC-20 token info, Uniswap V3 pool state, and to classify any address.",
    tools: [
      GetContractInfoTool,
      GetContractSourceTool,
      GetErc20InfoTool,
      GetUniswapV3PoolTool,
      InspectAddressTool,
      ReadContractStateTool
    ]
  )

  mcp_transport = MCP::Server::Transports::StreamableHTTPTransport.new(
    mcp_server,
    stateless: true
  )

  mount mcp_transport => "/mcp"

  # MCP subdomain root — human-facing setup docs for AI-agent integrators.
  # The `/mcp` mount above already serves the actual MCP protocol on this
  # host (and on smarts.md). This route only intercepts `/`.
  #
  # Matches prod (`mcp.smarts.md`) and the local-dev alias (`mcp.localhost`).
  # `.localhost` is the RFC 6761 reserved TLD: HSTS from *.smarts.md can't
  # leak into it, and modern resolvers map *.localhost → 127.0.0.1 without
  # needing /etc/hosts entries.
  constraints host: /\Amcp\.(?:smarts\.md|localhost)\z/ do
    root "marketing#mcp_docs", as: :mcp_docs
  end

  root "marketing#home"

  # Friendly slug: GET /uni-eth, /usdc-base, ... (curated whitelist only).
  # The pattern constraint rejects `/about`, `/api`, etc. — only strings ending
  # in a known chain suffix reach this route. Optional `.md` format returns
  # an AI-agent-friendly markdown distillation of the page.
  get ":slug(.:format)", to: "contracts#show", as: :contract_slug,
    constraints: { slug: ContractSlugs::ROUTE_PATTERN, format: /html|md/ }

  # Canonical hex form: GET /eth/0x1f98... — redirected to slug if one exists.
  # Supports the same optional `.md` format as the slug route.
  get ":chain/:address(.:format)", to: "contracts#show", as: :contract,
    constraints: { address: /0x[0-9a-fA-F]{40}/, format: /html|md/ }

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  # MCP discovery manifest (forward-looking, no formal spec yet). Served on
  # both smarts.md and mcp.smarts.md so crawlers and future auto-discovery
  # clients find it either way.
  get "/.well-known/mcp.json", to: "marketing#well_known_mcp", defaults: { format: :json }
end
