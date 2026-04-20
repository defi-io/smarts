class Chain < ApplicationRecord
  has_many :contracts, dependent: :destroy

  validates :name, :slug, :chain_id, :explorer_api_url, presence: true
  validates :slug, uniqueness: true
  validates :chain_id, uniqueness: true

  ETHERSCAN_V2_BASE = "https://api.etherscan.io/v2/api"

  def etherscan_url
    ETHERSCAN_V2_BASE
  end
end
