Rails.application.routes.draw do
  # MCP subdomain root — human-facing docs for AI agent integrators. The
  # same host still serves /mcp/sse + /mcp/messages via fast-mcp middleware
  # (mounted elsewhere), so this only intercepts `/`.
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
  # in a known chain suffix reach this route.
  get ":slug", to: "contracts#show", as: :contract_slug,
    constraints: { slug: ContractSlugs::ROUTE_PATTERN }

  # Canonical hex form: GET /eth/0x1f98... — redirected to slug if one exists.
  get ":chain/:address", to: "contracts#show", as: :contract,
    constraints: { address: /0x[0-9a-fA-F]{40}/ }

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
