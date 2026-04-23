Rails.application.routes.draw do
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
