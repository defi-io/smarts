# smarts.md

Live docs for every verified smart contract. Point your AI agent at one URL and ask about any contract on Ethereum, Base, Arbitrum, Optimism, or Polygon.

- Web: <https://smarts.md>
- MCP endpoint: `https://smarts.md/mcp` (Streamable HTTP, MCP spec 2025-03-26)
- MCP docs: <https://mcp.smarts.md>
- Discovery: <https://smarts.md/.well-known/mcp.json>

## Add to your AI agent

```bash
# Claude Code
claude mcp add --transport http smarts https://smarts.md/mcp
```

Cursor / Windsurf / Cline / Claude Desktop: see <https://mcp.smarts.md> for the per-client config snippet.

## Tools

| tool | what |
|---|---|
| `get_contract_info`    | metadata + classification + adapter tag |
| `get_contract_source`  | source index, file content, or grep across verified Solidity source |
| `get_erc20_info`       | supply, price, market cap, issuer, admin controls |
| `get_governance_timeline` | privileged-event history: role changes, upgrades, pauses, blacklisting, minter config |
| `get_recent_events`    | recent decoded contract events, optionally filtered by event name |
| `get_uniswap_v3_pool`  | pair, fee, price, liquidity, tick, TVL |
| `inspect_address`      | EOA vs contract, balance, nonce, reverse ENS |
| `read_contract_state`  | any view/pure function with args |

## Curated shortcuts

Use slugs anywhere a tool accepts `slug`; Smarts resolves them to chain + address.

- Stablecoins: `usdc-eth`, `usdt-eth`, `dai-eth`, `usde-eth`, `susde-eth`, `pyusd-eth`, `usdc-base`, `usdc-arbitrum`, `usdc-optimism`, `usdc-polygon`
- Governance tokens: `uni-eth`, `aave-eth`, `comp-eth`, `mkr-eth`, `sky-eth`, `ldo-eth`, `arb-arbitrum`, `op-optimism`, `aero-base`
- Protocol contracts: `univ3-factory-eth`, `univ3-swaprouter-eth`, `aavev3-pool-eth`, `aavev3-pool-base`, `aavev3-pool-arbitrum`
- Pools: `univ3-usdc-weth-eth`, `univ3-usdt-weth-eth`, `univ3-wbtc-weth-eth`, `univ3-dai-usdc-eth`

## Ask your AI

- "Is `usdc-eth` paused right now?"
- "TVL of `univ3-usdc-weth-eth`?"
- "Who is `0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045`?"
- "Total supply of `usdc-arbitrum`."

## Stack

Rails 8 + Postgres 17 + Hotwire + Tailwind, deployed via Kamal 2 to Hetzner. No TypeScript, no Node services. MCP server via the official `mcp` Ruby SDK.

## License

MIT — see [LICENSE](LICENSE).
