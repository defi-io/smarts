# Canonical chain registry — single source of truth.
#
# Add a new chain here, then run `bin/rails db:seed` (dev) or trigger
# `Chains::Seeder.call` (deploy hook / runner / spec setup). The seeder is
# idempotent: re-runs upsert by `slug`, never duplicates.
#
# Do NOT write per-chain data migrations. The previous pattern
# (db/migrate/*_add_<chain>_chain.rb) is deprecated; new chains belong here.

Object.send(:remove_const, :CHAIN_SEEDS) if Object.const_defined?(:CHAIN_SEEDS)
Object.send(:remove_const, :CHAIN_PRESENTATION) if Object.const_defined?(:CHAIN_PRESENTATION)

CHAIN_SEEDS = [
  # ── Tier 1 — full: live state + activity + governance via RPC. ──────────
  {
    name: "Ethereum", slug: "eth", chain_id: 1, tier: "full",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: "https://ethereum-rpc.publicnode.com"
  },
  {
    name: "Base", slug: "base", chain_id: 8453, tier: "full",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: "https://base-rpc.publicnode.com"
  },
  {
    name: "Arbitrum One", slug: "arbitrum", chain_id: 42161, tier: "full",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: "https://arb1.arbitrum.io/rpc"
  },
  {
    name: "Optimism", slug: "optimism", chain_id: 10, tier: "full",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: "https://optimism-rpc.publicnode.com"
  },
  {
    name: "BNB Smart Chain", slug: "bnb", chain_id: 56, tier: "full",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: "https://bsc-rpc.publicnode.com"
  },
  {
    name: "Polygon PoS", slug: "polygon", chain_id: 137, tier: "full",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: "https://polygon-bor-rpc.publicnode.com"
  },
  {
    name: "Robinhood Chain", slug: "robinhood", chain_id: 4663, tier: "full",
    # Etherscan V2 now lists chain 4663, but its new index still marks WETH's
    # verified implementation as unverified. Keep Blockscout for source/ABI
    # until Etherscan's proxy coverage is complete.
    explorer_api_url: "https://robinhoodchain.blockscout.com/api",
    rpc_url: "https://rpc.mainnet.chain.robinhood.com"
  },
  {
    name: "Arc", slug: "arc", chain_id: 5042, tier: "full",
    # ArcScan and Etherscan V2 added chain 5042 on 2026-09-16, but their source
    # index is not ready for Smarts yet: none of our six curated contracts can
    # be fetched end-to-end (USDC's proxy is verified, but its implementation
    # is not). Keep source/ABI on Sourcify while exposing ArcScan to users.
    explorer_api_url: "https://sourcify.dev/server",
    rpc_url: "https://rpc.mainnet.arc.io"
  },
  {
    name: "Ethereum Sepolia", slug: "sepolia", chain_id: 11_155_111, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Ethereum Hoodi", slug: "hoodi", chain_id: 560_048, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Polygon Amoy", slug: "polygon-amoy", chain_id: 80_002, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Arbitrum Sepolia", slug: "arbitrum-sepolia", chain_id: 421_614, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Linea Sepolia", slug: "linea-sepolia", chain_id: 59_141, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Blast Sepolia", slug: "blast-sepolia", chain_id: 168_587_773, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Celo Sepolia", slug: "celo-sepolia", chain_id: 11_142_220, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Fraxtal Hoodi", slug: "fraxtal-hoodi", chain_id: 2_523, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Moonbeam", slug: "moonbeam", chain_id: 1_284, tier: "docs_only", network_kind: "mainnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Moonriver", slug: "moonriver", chain_id: 1_285, tier: "docs_only", network_kind: "mainnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Moonbase Alpha", slug: "moonbase", chain_id: 1_287, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "opBNB", slug: "opbnb", chain_id: 204, tier: "docs_only", network_kind: "mainnet",
    # Etherscan V2 dropped opBNB (chain IDs 204/5611) on 2026-10-12; Sourcify serves both.
    explorer_api_url: "https://sourcify.dev/server",
    rpc_url: nil
  },
  {
    name: "opBNB Testnet", slug: "opbnb-testnet", chain_id: 5_611, tier: "docs_only", network_kind: "testnet",
    # Etherscan V2 dropped opBNB (chain IDs 204/5611) on 2026-10-12; Sourcify serves both.
    explorer_api_url: "https://sourcify.dev/server",
    rpc_url: nil
  },
  {
    name: "XDC Mainnet", slug: "xdc", chain_id: 50, tier: "docs_only", network_kind: "mainnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "XDC Apothem", slug: "xdc-apothem", chain_id: 51, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Unichain Sepolia", slug: "unichain-sepolia", chain_id: 1_301, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "World Chain Sepolia", slug: "world-sepolia", chain_id: 4_801, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Berachain Bepolia", slug: "berachain-bepolia", chain_id: 80_069, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Monad", slug: "monad", chain_id: 143, tier: "docs_only", network_kind: "mainnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Monad Testnet", slug: "monad-testnet", chain_id: 10_143, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "HyperEVM", slug: "hyperevm", chain_id: 999, tier: "docs_only", network_kind: "mainnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "HyperEVM Testnet", slug: "hyperevm-testnet", chain_id: 998, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Katana", slug: "katana", chain_id: 747_474, tier: "docs_only", network_kind: "mainnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Katana Bokuto", slug: "bokuto", chain_id: 737_373, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Sei", slug: "sei", chain_id: 1_329, tier: "docs_only", network_kind: "mainnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Sei Testnet", slug: "sei-testnet", chain_id: 1_328, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Stable", slug: "stable", chain_id: 988, tier: "docs_only", network_kind: "mainnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Stable Testnet", slug: "stable-testnet", chain_id: 2_201, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Plasma", slug: "plasma", chain_id: 9_745, tier: "docs_only", network_kind: "mainnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Plasma Testnet", slug: "plasma-testnet", chain_id: 9_746, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "MegaETH", slug: "megaeth", chain_id: 4_326, tier: "docs_only", network_kind: "mainnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "MegaETH Testnet", slug: "megaeth-testnet", chain_id: 6_343, tier: "docs_only", network_kind: "testnet",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Arc Testnet", slug: "arc-testnet", chain_id: 5_042_002, tier: "docs_only", network_kind: "testnet",
    # Unlike mainnet, the Arc testnet explorer is a public Blockscout with the
    # Etherscan-compatible /api shim enabled (its `proxy` module is off, which
    # we never use — events go through RPC).
    explorer_api_url: "https://testnet.arcscan.app/api",
    rpc_url: "https://rpc.testnet.arc.io"
  },

  # ── Tier 2 — docs_only: Etherscan source/ABI only, no RPC, no live data. ─
  # Order roughly by ecosystem maturity / search demand. Etherscan V2 Free tier
  # serves `getsourcecode` / `getabi` for ALL supported chains — that's the
  # entire reason Tier 2 costs $0 to operate.
  {
    name: "Linea", slug: "linea", chain_id: 59144, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Unichain", slug: "unichain", chain_id: 130, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Berachain", slug: "berachain", chain_id: 80094, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Blast", slug: "blast", chain_id: 81457, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Sonic", slug: "sonic", chain_id: 146, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Mantle", slug: "mantle", chain_id: 5000, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Gnosis", slug: "gnosis", chain_id: 100, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Celo", slug: "celo", chain_id: 42220, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Fraxtal", slug: "fraxtal", chain_id: 252, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Taiko", slug: "taiko", chain_id: 167000, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "World Chain", slug: "world", chain_id: 480, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  },
  {
    name: "Abstract", slug: "abstract", chain_id: 2741, tier: "docs_only",
    explorer_api_url: "https://api.etherscan.io/v2/api",
    rpc_url: nil
  }
].freeze

CHAIN_PRESENTATION = {
  "eth" => {
    summary: "Blue-chip Ethereum contracts for stablecoins, DeFi, and core protocol plumbing."
  },
  "base" => {
    summary: "Base-native stablecoin, DEX, and lending contracts built on the OP Stack."
  },
  "arbitrum" => {
    summary: "Native stablecoin and lending contracts on Arbitrum One."
  },
  "optimism" => {
    summary: "Optimism-native stablecoins, governance tokens, and lending markets."
  },
  "bnb" => {
    summary: "The biggest BNB Chain primitives: stablecoins, wrapped gas, and PancakeSwap."
  },
  "polygon" => {
    summary: "Polygon's canonical stablecoins, wrapped gas token, and Polymarket infrastructure."
  },
  "sepolia" => {
    docs_url: "https://ethereum.org/developers/docs/networks/",
    explorer_url: "https://sepolia.etherscan.io",
    faucet_url: "https://www.alchemy.com/faucets/ethereum-sepolia",
    verify_url: "https://sepolia.etherscan.io/verifyContract"
  },
  "hoodi" => {
    docs_url: "https://hoodi.ethpandaops.io/",
    explorer_url: "https://hoodi.etherscan.io",
    faucet_url: "https://faucet.hoodi.ethpandaops.io/",
    verify_url: "https://hoodi.etherscan.io/verifyContract"
  },
  "polygon-amoy" => {
    docs_url: "https://docs.polygon.technology/pos/reference/rpc-endpoints/",
    explorer_url: "https://amoy.polygonscan.com",
    faucet_url: "https://faucet.polygon.technology/",
    verify_url: "https://amoy.polygonscan.com/verifyContract"
  },
  "arbitrum-sepolia" => {
    docs_url: "https://docs.arbitrum.io/",
    explorer_url: "https://sepolia.arbiscan.io",
    faucet_url: "https://www.alchemy.com/faucets/arbitrum-sepolia",
    verify_url: "https://sepolia.arbiscan.io/verifyContract"
  },
  "linea-sepolia" => {
    docs_url: "https://docs.linea.build/",
    explorer_url: "https://sepolia.lineascan.build",
    verify_url: "https://sepolia.lineascan.build/verifyContract"
  },
  "blast-sepolia" => {
    docs_url: "https://docs.blast.io/building/network-information",
    explorer_url: "https://sepolia.blastscan.io",
    faucet_url: "https://docs.blast.io/tools/faucets",
    verify_url: "https://sepolia.blastscan.io/verifyContract"
  },
  "celo-sepolia" => {
    docs_url: "https://docs.celo.org/learn/topology-of-a-celo-network",
    explorer_url: "https://celo-sepolia.blockscout.com",
    faucet_url: "https://faucet.celo.org/celo-sepolia",
    verify_url: "https://celo-sepolia.blockscout.com/verifyContract"
  },
  "fraxtal-hoodi" => {
    docs_url: "https://docs.frax.com/fraxtal/network/network-information",
    explorer_url: "https://hoodi.fraxscan.com",
    faucet_url: "https://docs.frax.com/fraxtal/tools/faucets"
  },
  "moonbase" => {
    docs_url: "https://docs.moonbeam.network/builders/get-started/networks/moonbase/",
    explorer_url: "https://moonbase.moonscan.io"
  },
  "opbnb-testnet" => {
    docs_url: "https://docs.bnbchain.org/bnb-opbnb/get-started/network-info/",
    explorer_url: "https://testnet.opbnbscan.com",
    faucet_url: "https://docs.bnbchain.org/bnb-opbnb/developers/network-faucet/",
    verify_url: "https://docs.bnbchain.org/bnb-opbnb/advanced/verify-on-opbnbscan/"
  },
  "xdc-apothem" => {
    docs_url: "https://docs.xdc.network/xdcchain/developers/apothemrpc/",
    explorer_url: "https://testnet.xdcscan.com"
  },
  "unichain-sepolia" => {
    docs_url: "https://docs.unichain.org/docs/technical-information/network-information",
    explorer_url: "https://sepolia.uniscan.xyz",
    faucet_url: "https://docs.unichain.org/docs/tools/faucets",
    verify_url: "https://docs.unichain.org/docs/building-on-unichain/deploy-a-smart-contract"
  },
  "world-sepolia" => {
    docs_url: "https://docs.world.org/world-chain/quick-start/info",
    explorer_url: "https://worldchain-sepolia.explorer.alchemy.com",
    faucet_url: "https://www.alchemy.com/faucets/world-chain-sepolia",
    verify_url: "https://docs.world.org/world-chain/developers/deploy"
  },
  "berachain-bepolia" => {
    docs_url: "https://docs.berachain.com/build/getting-started/common-resources",
    explorer_url: "https://testnet.berascan.com",
    faucet_url: "https://bepolia.hub.berachain.com",
    verify_url: "https://docs.berachain.com/build/guides/verifying-smart-contracts"
  },
  "monad" => {
    docs_url: "https://docs.monad.xyz/"
  },
  "monad-testnet" => {
    docs_url: "https://docs.monad.xyz/",
    explorer_url: "https://testnet.monadvision.com",
    faucet_url: "https://faucet.monad.xyz/",
    verify_url: "https://docs.monad.xyz/"
  },
  "hyperevm" => {
    docs_url: "https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm",
    explorer_url: "https://hyperscan.com"
  },
  "hyperevm-testnet" => {
    docs_url: "https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm",
    explorer_url: "https://hyperscan.com",
    faucet_url: "https://app.hyperliquid-testnet.xyz/drip"
  },
  "katana" => {
    docs_url: "https://docs.katana.network/katana/technical-reference/network-information/"
  },
  "bokuto" => {
    docs_url: "https://docs.katana.network/katana/get-started/technical-reference-testnet/",
    explorer_url: "https://bokuto.katanascan.com",
    faucet_url: "https://explorer-bokuto.katanarpc.com/",
    verify_url: "https://docs.katana.network/katana/get-started/technical-reference-testnet/"
  },
  "sei" => {
    docs_url: "https://www.docs.sei.io/evm"
  },
  "sei-testnet" => {
    docs_url: "https://www.docs.sei.io/evm",
    explorer_url: "https://testnet.seiscan.io",
    faucet_url: "https://docs.sei.io/providers/faucets",
    verify_url: "https://docs.sei.io/evm/evm-verify-contracts"
  },
  "stable" => {
    docs_url: "https://docs.stable.xyz/en/developers/mainnet/mainnet-information"
  },
  "stable-testnet" => {
    docs_url: "https://docs.stable.xyz/en/developers/testnet/testnet-information",
    explorer_url: "https://testnet.stablescan.xyz",
    faucet_url: "https://faucet.stable.xyz",
    verify_url: "https://testnet.stablescan.xyz/verifyContract"
  },
  "plasma" => {
    docs_url: "https://docs.plasma.to/docs/guides/network-configuration/mainnet-details"
  },
  "plasma-testnet" => {
    docs_url: "https://docs.plasma.to/docs/guides/network-configuration/testnet-details",
    explorer_url: "https://testnet.plasmascan.to",
    faucet_url: "https://gas.zip/faucet/plasma",
    verify_url: "https://docs.plasma.to/docs/guides/smart-contracts/verify-a-contract"
  },
  "megaeth" => {
    docs_url: "https://docs.megaeth.com/frontier"
  },
  "megaeth-testnet" => {
    docs_url: "https://docs.megaeth.com/testnet",
    faucet_url: "https://testnet.megaeth.com"
  },
  "arc" => {
    summary: "Circle's Arc L1: native USDC gas, EURC and USYC, and the StableFX settlement escrow.",
    docs_url: "https://docs.arc.io/arc/references/contract-addresses",
    explorer_url: "https://arc.etherscan.io",
    verify_url: "https://arc.etherscan.io/verifyContract"
  },
  "arc-testnet" => {
    docs_url: "https://docs.arc.io/arc/references/contract-addresses",
    faucet_url: "https://faucet.circle.com"
  },
  "linea" => {
    summary: "Docs-only Linea contracts from the ecosystem's native tokens and leading apps.",
    docs_url: "https://docs.linea.build/"
  },
  "unichain" => {
    summary: "Unichain's core contracts for v2, v3, v4, and native token deployment.",
    docs_url: "https://docs.unichain.org/docs/technical-information/contract-addresses"
  },
  "berachain" => {
    summary: "Berachain BEX and Proof-of-Liquidity contracts plus the native tokens.",
    docs_url: "https://docs.berachain.com/build/bex/deployed-contracts"
  },
  "blast" => {
    summary: "Blast's core bridge and token contracts on the L2.",
    docs_url: "https://docs.blast.io/building/contracts"
  },
  "sonic" => {
    summary: "Sonic's core gas, bridge, and gateway infrastructure contracts.",
    docs_url: "https://docs.soniclabs.com/sonic/build-on-sonic/contract-addresses"
  },
  "mantle" => {
    summary: "Mantle contracts pulled from ecosystem deployment guides and protocol docs.",
    docs_url: "https://docs.dodoex.io/en/developer/contracts/dodo-v1-v2/contracts-address/mantle"
  },
  "gnosis" => {
    summary: "Gnosis Chain bridge, staking, and token contracts from the ecosystem docs.",
    docs_url: "https://docs.gnosischain.com/about/specs/gbc/"
  },
  "celo" => {
    summary: "Celo's core governance, bridge, and Uniswap deployment addresses.",
    docs_url: "https://docs.celo.org/contracts/core-contracts"
  },
  "fraxtal" => {
    summary: "Fraxtal's native stablecoins, Fraxswap, and name service contracts.",
    docs_url: "https://docs.frax.com/fraxtal/addresses/frax-tokens"
  },
  "taiko" => {
    summary: "Taiko Alethia bridge, tokens, and operator contracts surfaced in explorer pages.",
    docs_url: "https://taikoscan.io/address/0x1670000000000000000000000000000000000001"
  },
  "world" => {
    summary: "World Chain contracts for identity, tokens, and account abstraction primitives.",
    docs_url: "https://docs.world.org/world-chain/developers/world-chain-contracts"
  },
  "abstract" => {
    summary: "Abstract system contracts that power account abstraction and deployment.",
    docs_url: "https://docs.abs.xyz/how-abstract-works/system-contracts/list-of-system-contracts"
  }
}.freeze

CHAIN_SEEDS.each do |attrs|
  attrs.merge!(CHAIN_PRESENTATION.fetch(attrs[:slug], {}))
end
