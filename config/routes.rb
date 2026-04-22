Rails.application.routes.draw do
  root "marketing#home"

  # Contract docs: GET /eth/0x1f98...
  get ":chain/:address", to: "contracts#show", as: :contract,
    constraints: { address: /0x[0-9a-fA-F]{40}/ }

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
