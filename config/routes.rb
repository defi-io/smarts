Rails.application.routes.draw do
  resources :users, only: %i[new create]
  resource :session
  resources :passwords, param: :token
  resources :accounts, only: :index
  namespace :auth do
    get "x", to: "x#authorize", as: :x
    get "x/callback", to: "x#callback", as: :x_callback
  end

  mount MissionControl::Jobs::Engine, at: "/jobs"

  namespace :admin do
    resources :articles, only: %i[index edit update]
  end

  get "my", to: "my#show"

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
    instructions: "Live docs for verified smart contracts on Ethereum, Base, Arbitrum, Optimism, BNB Smart Chain, Polygon, Robinhood Chain, and Arc. Use these tools to read on-chain state, ERC-20 token info, Uniswap V3 pool state, pool discovery and swap quotes, Aave V3 lending markets, DefiLlama stablecoin supply / protocol TVL / yield pools, and to classify any address.",
    tools: [
      FindUniswapV3PoolsTool,
      GetContractInfoTool,
      GetContractSourceTool,
      GetAdminRiskTool,
      GetAaveV3MarketTool,
      GetErc20InfoTool,
      GetPolymarketMarketTool,
      GetPolymarketPositionTool,
      GetPolymarketResolutionTool,
      GetProtocolTvlTool,
      GetRecentEventsTool,
      GetStablecoinSupplyTool,
      GetUniswapV3PoolTool,
      GetYieldPoolsTool,
      InspectAddressTool,
      ListArticleDraftsTool,
      PublishArticleTool,
      QuoteUniswapV3SwapTool,
      ValidateArticleDraftTool,
      ReadContractStateTool
    ]
  )

  # mcp >= 0.23 rejects any Host outside 127.0.0.1/::1/localhost (DNS-rebinding
  # protection), so every host that serves /mcp must be listed here or the
  # endpoint answers 403 "Invalid Host header". Keep in sync with the proxy
  # hosts in config/deploy.yml and the dev hosts in development.rb.
  mcp_allowed_hosts = %w[smarts.md mcp.smarts.md]
  mcp_allowed_hosts += %w[mcp.localhost d.smarts.md] if Rails.env.development?
  mcp_allowed_hosts += %w[www.example.com] if Rails.env.test? # integration-test default host

  mcp_transport = MCP::Server::Transports::StreamableHTTPTransport.new(
    mcp_server,
    stateless: true,
    allowed_hosts: mcp_allowed_hosts
  )

  # Wrap the transport so each request authenticates an optional
  # `Authorization: Bearer <publish_token>` and surfaces the user on
  # `Current.mcp_user` for downstream tools.
  mcp_app = Rack::Builder.new do
    use McpBearerAuth
    run mcp_transport
  end.to_app

  mount mcp_app => "/mcp"

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

  # Localized home with optional locale prefix
  get ":locale", to: "marketing#home", as: :localized_home,
    constraints: { locale: Regexp.union(Article::LOCALE_ROUTE_MAP.keys) }

  root "marketing#home"

  get ":locale/chains", to: "chains#index", as: :localized_chains,
    constraints: { locale: Regexp.union(Article::LOCALE_ROUTE_MAP.keys) }
  get "chains", to: "chains#index"
  get ":locale/testnets", to: "chains#index", as: :localized_testnets,
    defaults: { scope: "testnets", network: "testnet" },
    constraints: { locale: Regexp.union(Article::LOCALE_ROUTE_MAP.keys) }
  get "testnets", to: "chains#index", defaults: { scope: "testnets", network: "testnet" }
  get ":locale/chains/:slug(.:format)", to: "chains#show", as: :localized_chain,
    constraints: { locale: Regexp.union(Article::LOCALE_ROUTE_MAP.keys), slug: /[a-z0-9-]+/, format: /html|md/ }
  get "chains/:slug(.:format)", to: "chains#show", as: :chain,
    constraints: { slug: /[a-z0-9-]+/, format: /html|md/ }

  get "polymarket", to: "marketing#polymarket"
  get "sitemap.xml", to: "marketing#sitemap", defaults: { format: :xml }
  get "robots.txt", to: "marketing#robots", defaults: { format: :text }

  # Articles list with optional locale prefix
  get ":locale/articles", to: "articles#index", as: :localized_articles,
    constraints: { locale: Regexp.union(Article::LOCALE_ROUTE_MAP.keys) }
  resources :articles, only: :index

  # Health check. Keep this explicit route before the two-character article
  # route so `/up` never becomes a publishable article URL.
  get "up" => "rails/health#show", as: :rails_health_check

  # Minimal article URLs:
  #   /7g      => English/default
  #   /cn/7g   => Simplified Chinese
  #   /tw/7g   => Traditional Chinese
  get ":locale/:slug", to: "articles#show", as: :localized_article,
    constraints: { locale: Regexp.union(Article::LOCALE_ROUTE_MAP.keys), slug: Article::SLUG_PATTERN }
  get ":slug", to: "articles#show", as: :article,
    constraints: { slug: Article::SLUG_PATTERN }

  # Contract sub-resource endpoints (Turbo Frame islands).
  # These MUST sit before the slug / hex catch-all routes so Rails tries them
  # first; otherwise `:slug` would swallow "usdc-eth/live" as a single param.
  %w[live activity source].each do |island|
    get ":locale/:slug/#{island}", to: "contracts##{island}",
      constraints: { locale: Regexp.union(Article::LOCALE_ROUTE_MAP.keys), slug: ContractSlugResolver::ROUTE_PATTERN }
    get ":locale/:chain/:address/#{island}", to: "contracts##{island}",
      constraints: { locale: Regexp.union(Article::LOCALE_ROUTE_MAP.keys), address: /0x[0-9a-fA-F]{40}/ }
    get ":slug/#{island}", to: "contracts##{island}",
      constraints: { slug: ContractSlugResolver::ROUTE_PATTERN }
    get ":chain/:address/#{island}", to: "contracts##{island}",
      constraints: { address: /0x[0-9a-fA-F]{40}/ }
  end

  # Friendly slug: GET /uni-eth, /usdc-base, ... (curated whitelist only).
  # The pattern constraint rejects `/about`, `/api`, etc. — only strings ending
  # in a known chain suffix reach this route. Optional `.md` format returns
  # an AI-agent-friendly markdown distillation of the page.
  get ":locale/:slug(.:format)", to: "contracts#show", as: :localized_contract_slug,
    constraints: { locale: Regexp.union(Article::LOCALE_ROUTE_MAP.keys), slug: ContractSlugResolver::ROUTE_PATTERN, format: /html|md/ }
  get ":slug(.:format)", to: "contracts#show", as: :contract_slug,
    constraints: { slug: ContractSlugResolver::ROUTE_PATTERN, format: /html|md/ }

  # Canonical hex form: GET /eth/0x1f98... — redirected to slug if one exists.
  # Supports the same optional `.md` format as the slug route.
  get ":locale/:chain/:address(.:format)", to: "contracts#show", as: :localized_contract,
    constraints: { locale: Regexp.union(Article::LOCALE_ROUTE_MAP.keys), address: /0x[0-9a-fA-F]{40}/, format: /html|md/ }
  get ":chain/:address(.:format)", to: "contracts#show", as: :contract,
    constraints: { address: /0x[0-9a-fA-F]{40}/, format: /html|md/ }

  # REST API for ChatGPT Custom GPTs and other OpenAPI consumers.
  # Each MCP tool is accessible as GET /api/v1/:tool_name?params.
  namespace :api do
    namespace :v1 do
      get ":tool_name", to: "tools#show", as: :tool
    end
  end

  # Discovery manifests. Served on both smarts.md and mcp.smarts.md so
  # crawlers and auto-discovery clients find them either way.
  get "/.well-known/ai-plugin.json", to: "marketing#ai_plugin", defaults: { format: :json }
  get "/api/openapi.json", to: "marketing#openapi_spec", defaults: { format: :json }
  get "/.well-known/mcp.json", to: "marketing#well_known_mcp", defaults: { format: :json }
end
