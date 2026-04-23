# smarts.md

Live docs for every verified smart contract. Point your AI agent at one URL and ask about any contract on Ethereum, Base, Arbitrum, Optimism, or Polygon.

- Web: <https://smarts.md>
- MCP endpoint: `https://smarts.md/mcp/sse`
- MCP docs: <https://mcp.smarts.md>
- Discovery: <https://smarts.md/.well-known/mcp.json>

## Add to your AI agent

```bash
# Claude Code
claude mcp add --transport sse smarts https://smarts.md/mcp/sse
```

Cursor / Windsurf / Cline / Claude Desktop: see <https://mcp.smarts.md> for the per-client config snippet.

## Tools

| tool | what |
|---|---|
| `get_contract_info`    | metadata + classification + adapter tag |
| `get_erc20_info`       | supply, price, market cap, issuer, admin controls |
| `get_uniswap_v3_pool`  | pair, fee, price, liquidity, tick, TVL |
| `inspect_address`      | EOA vs contract, balance, nonce, reverse ENS |
| `read_contract_state`  | any view/pure function with args |

## Ask your AI

- "Is `usdc-eth` paused right now?"
- "TVL of `univ3-usdc-weth-eth`?"
- "Who is `0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045`?"
- "Total supply of `usdc-arbitrum`."

## Stack

Rails 8 + Postgres 17 + Hotwire + Tailwind, deployed via Kamal 2 to Hetzner. No TypeScript, no Node services. MCP server via `fast-mcp`.

## License

MIT — see [LICENSE](LICENSE).
