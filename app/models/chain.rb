class Chain < ApplicationRecord
  has_many :contracts, dependent: :destroy

  validates :name, :slug, :chain_id, :explorer_api_url, presence: true
  validates :slug, uniqueness: true
  validates :chain_id, uniqueness: true

  ETHERSCAN_V2_BASE = "https://api.etherscan.io/v2/api"

  # Gas-token symbol for each chain's native currency (shown in balance displays).
  NATIVE_SYMBOLS = {
    "eth"      => "ETH",
    "base"     => "ETH",
    "arbitrum" => "ETH",
    "optimism" => "ETH",
    "polygon"  => "MATIC"
  }.freeze

  def etherscan_url
    ETHERSCAN_V2_BASE
  end

  def native_symbol
    NATIVE_SYMBOLS[slug] || "ETH"
  end
end
