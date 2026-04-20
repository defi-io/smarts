chains = [
  { name: "Ethereum", slug: "eth", chain_id: 1, explorer_api_url: "https://api.etherscan.io/v2/api" },
  { name: "Base", slug: "base", chain_id: 8453, explorer_api_url: "https://api.etherscan.io/v2/api" },
  { name: "Arbitrum One", slug: "arbitrum", chain_id: 42161, explorer_api_url: "https://api.etherscan.io/v2/api" },
  { name: "Optimism", slug: "optimism", chain_id: 10, explorer_api_url: "https://api.etherscan.io/v2/api" },
  { name: "Polygon PoS", slug: "polygon", chain_id: 137, explorer_api_url: "https://api.etherscan.io/v2/api" }
]

chains.each do |attrs|
  Chain.find_or_create_by!(slug: attrs[:slug]) do |chain|
    chain.assign_attributes(attrs)
  end
end

puts "Seeded #{Chain.count} chains"
