class Chain < ApplicationRecord
  has_many :contracts, -> { order(Arel.sql("catalog_order ASC NULLS LAST"), :name) }, dependent: :destroy

  # full: live state + activity + governance via RPC (Tier 1, ~6 chains)
  # docs_only: Etherscan source/ABI only — no RPC, no live data (Tier 2, long-tail EVM)
  enum :tier, { full: "full", docs_only: "docs_only" }, default: :full
  enum :network_kind, { mainnet: "mainnet", testnet: "testnet" }, default: :mainnet

  validates :name, :slug, :chain_id, :explorer_api_url, presence: true
  validates :slug, uniqueness: true
  validates :chain_id, uniqueness: true

  # User-facing display order for chain selectors and labels. Seeded records
  # also persist this value in display_order so database reads can keep the same
  # order without depending on an in-memory catalog.
  DISPLAY_ORDER = %w[
    eth base bnb arbitrum optimism polygon robinhood
    sepolia hoodi polygon-amoy arbitrum-sepolia linea-sepolia blast-sepolia celo-sepolia fraxtal-hoodi
    moonbeam moonriver moonbase opbnb opbnb-testnet xdc xdc-apothem unichain-sepolia world-sepolia berachain-bepolia
    monad monad-testnet hyperevm hyperevm-testnet katana bokuto sei sei-testnet stable stable-testnet plasma plasma-testnet megaeth megaeth-testnet
    linea unichain berachain blast sonic mantle gnosis celo fraxtal taiko world abstract
  ].freeze

  scope :for_display, -> { order(Arel.sql("display_order ASC NULLS LAST"), :name) }

  # Hash of { slug => name } in display order. Replaces the old
  # MarketingController::CHAIN_LABELS hardcoded constant — single source of
  # truth is now Chain rows (seeded from db/seeds/chains.rb).
  def self.labels
    for_display.pluck(:slug, :name).to_h
  end

  # Gas-token symbol for each chain's native currency (shown in balance displays).
  NATIVE_SYMBOLS = {
    "eth"       => "ETH",
    "base"      => "ETH",
    "arbitrum"  => "ETH",
    "optimism"  => "ETH",
    "bnb"       => "BNB",
    "polygon"   => "MATIC",
    "robinhood" => "ETH"
  }.freeze

  def etherscan_url
    explorer_api_url
  end

  # Picks the source/ABI client for this chain. Blockscout instances serve the
  # same Etherscan-style endpoints under /api, so the seeded API URL is enough
  # to identify them — the same inference EtherscanClient already uses to
  # decide whether to send `chainid`.
  def explorer_client
    if explorer_api_url.to_s.include?("blockscout")
      BlockscoutClient.new(self)
    else
      EtherscanClient.new(self)
    end
  end

  def native_symbol
    NATIVE_SYMBOLS[slug] || "ETH"
  end

  def summary
    self[:summary].presence || default_summary
  end

  def path(locale: I18n.locale)
    route_locale = Article.route_locale_for(locale.to_s)
    route_locale.present? ? "/#{route_locale}/chains/#{slug}" : "/chains/#{slug}"
  end

  private

  def default_summary
    if testnet?
      "#{name} testnet contracts and explorer-supported tooling."
    elsif docs_only?
      "#{name} contracts surfaced from ecosystem docs and explorer pages."
    else
      "#{name} contracts with live state, activity, and governance coverage."
    end
  end
end
