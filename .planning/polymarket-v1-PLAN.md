# Polymarket Adapter — PLAN.md

> Branch: `feat/polymarket-v1`
> Status: **Phase A mostly implemented — adapter/client/fetchers/tools/docs in tree**
> Scope: Phase A (on-chain adapter + slug-based MCP tools) + Phase B (off-chain orderbook integration)
> Last updated: 2026-05-19

---

## Why this exists

Polymarket is the dominant prediction-market protocol on Polygon. For an AI agent, "what does the market think about X event happening" is one of the highest-signal on-chain queries possible — and it's a natural MCP use case. Smarts is the only project positioned to expose this as a verified-contract live doc + agent-ready endpoint.

This deviates from the MVP "DeFi Top 50" rail but stays inside the supported-chains boundary (Polygon, already wired). CLAUDE.md will gain a documented exception (see §10).

---

## Scope decisions (locked before drafting)

| Decision | Choice | Rationale |
|---|---|---|
| Off-chain HTTP API | **Allowed for Polymarket** (single documented exception) | Order book is purely off-chain; without it the "current odds" question — the whole point — can't be answered |
| Market discovery primary input | **Slug** with `condition_id` fallback | Slug is what humans/agents actually know; condition_id is the stable internal key |
| Phase split | A: on-chain only (metadata + resolution + balances) → B: orderbook integration | A is shippable standalone; B is purely additive |
| Adapter granularity | One `PolymarketAdapter` matching all Polymarket addresses by allow-list | Six+ contracts to recognize, all share a protocol identity — sub-roles handled by `template_partial` branching |
| Position tool discovery | User passes `address` + explicit `condition_ids` / `slugs` array | Cross-market discovery via Polymarket data-api is deferred (out of scope here) |

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                          MCP tools                                  │
│                                                                     │
│  GetPolymarketMarketTool        GetPolymarketPositionTool          │
│  (slug OR condition_id)         (address + condition_ids[])        │
└──────────────┬──────────────────────────┬───────────────────────────┘
               │                          │
               ▼                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Polymarket::MarketFetcher    Polymarket::PositionFetcher          │
│  (orchestrator: slug → meta   (orchestrator: condition_id +        │
│   + resolution + on-chain     address → position IDs → balances    │
│   volumes + Phase B: prices)   + redemption state)                  │
└────┬──────────────────────────────────┬─────────────────────────────┘
     │                                  │
     ├─► PolymarketClient (gamma+CLOB)  │
     │                                  │
     └─► ChainReader::                  └─► ChainReader::
         ConditionalTokensReader            ConditionalTokensReader
         (positionId, payoutDenominator,
         payoutNumerators, balanceOf via Multicall3)

┌─────────────────────────────────────────────────────────────────────┐
│   PolymarketAdapter (resolves at contract show page level)         │
│   - matches?(contract): allow-list of Polymarket addresses         │
│   - template_partial: branches per role (exchange / ctf /          │
│     uma-adapter / neg-risk-adapter)                                │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Address allow-list

All on Polygon (chain slug `polygon`). Roles:

| Slug | Address | Role | Adapter behavior |
|---|---|---|---|
| `polymarket-ctf-exchange-v1-polygon` | `0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E` | Binary order matching (USDC.e collateral) | Exchange panel |
| `polymarket-ctf-exchange-v2-polygon` | `0xE111180000d2663C0091e4f400237545B87B996B` | V2 exchange (Polymarket USD collateral) | Exchange panel |
| `polymarket-neg-risk-exchange-v1-polygon` | `0xC5d563A36AE78145C45a50134d48A1215220f80a` | Multi-outcome exchange V1 | Exchange panel |
| `polymarket-neg-risk-exchange-v2-polygon` | `0xe2222d279d744050d28e00520010520000310F59` | Multi-outcome exchange V2 | Exchange panel |
| `polymarket-neg-risk-adapter-polygon` | `0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296` | Neg-risk oracle + split/merge | Adapter panel |
| `polymarket-conditional-tokens-polygon` | `0x4D97DCd97eC945f40cF65F87097ACe5EA0476045` | ERC-1155 outcome token (Gnosis CTF) | CTF panel |
| `polymarket-uma-adapter-v1-polygon` | `0x71392E133063CC0D16F40E1F9B60227404Bc03f7` | Legacy binary adapter | UMA-adapter panel |
| `polymarket-uma-adapter-v2-polygon` | `0x6A9D222616C90FcA5754cd1333cFD9b7fb6a4F74` | Current binary adapter | UMA-adapter panel |
| `polymarket-uma-adapter-v3-polygon` | `0x2F5e3684cb1F318ec51b00Edba38d79Ac2c0aA9d` | V3 adapter | UMA-adapter panel |

Notes:
- UMA OptimisticOracleV2 address is **not hardcoded** — read it at runtime from the active adapter's `oracle()` getter or via UMA Finder. Not added to curated slugs (UMA is its own protocol, out of scope here).
- Each Polymarket contract in the table above gets a curated slug entry in `app/services/contract_slugs.rb`.

---

## File inventory

### New files

```
app/services/
├── polymarket_client.rb                       # NEW — Faraday client for gamma + CLOB
├── polymarket/
│   ├── market_fetcher.rb                      # NEW — orchestrates metadata + resolution + on-chain
│   ├── position_fetcher.rb                    # NEW — derives position IDs + reads balances
│   └── resolution_reader.rb                   # NEW — reads payoutDenominator + UmaCtfAdapter flags
├── chain_reader/
│   └── conditional_tokens_reader.rb           # NEW — Gnosis CTF derivation + reads
└── protocol_adapters/
    └── polymarket_adapter.rb                  # NEW — matches Polymarket addresses, branches partial

app/tools/
├── get_polymarket_market_tool.rb              # NEW — slug/condition_id → market state
└── get_polymarket_position_tool.rb            # NEW — address + condition_ids → balances

app/views/protocol_adapters/
├── _polymarket_exchange.html.erb              # NEW — CTFExchange / NegRiskCtfExchange panel
├── _polymarket_exchange.md.erb
├── _polymarket_ctf.html.erb                   # NEW — ConditionalTokens panel
├── _polymarket_ctf.md.erb
├── _polymarket_uma_adapter.html.erb           # NEW — UmaCtfAdapter panel
├── _polymarket_uma_adapter.md.erb
├── _polymarket_neg_risk_adapter.html.erb      # NEW — NegRiskAdapter panel
└── _polymarket_neg_risk_adapter.md.erb

test/services/
├── polymarket_client_test.rb                  # NEW — VCR cassettes for gamma + CLOB
├── polymarket/
│   ├── market_fetcher_test.rb                 # NEW
│   ├── position_fetcher_test.rb               # NEW
│   └── resolution_reader_test.rb              # NEW
├── chain_reader/
│   └── conditional_tokens_reader_test.rb      # NEW
└── protocol_adapters/
    └── polymarket_adapter_test.rb             # NEW

test/tools/
├── get_polymarket_market_tool_test.rb         # NEW
└── get_polymarket_position_tool_test.rb       # NEW
```

### Modified files

```
app/services/contract_slugs.rb                 # +9 Polymarket entries
app/services/protocol_adapters/base.rb         # add PolymarketAdapter to ADAPTER_NAMES (highest priority)
CLAUDE.md                                      # +Polymarket section + off-chain API exception
```

---

## Dependency order (commit-by-commit plan)

Commits are intentionally small and reviewable. Each one should leave tests green.

### Phase A

1. **`chore(slugs): register Polymarket contracts on Polygon`** ✅
   - Add 9 entries to `ContractSlugs::MAP`
   - Update `contract_slugs_test.rb`
   - No behavior change yet; just slug resolution

2. **`feat(chain_reader): add ConditionalTokensReader`** ✅
   - `app/services/chain_reader/conditional_tokens_reader.rb`
   - Position ID derivation (parent=bytes32(0), uses `Eth::Abi.solidity_packed_keccak256` pattern)
   - Multicall3-batched reads for `balanceOf(account, positionId)`, `payoutDenominator(conditionId)`, `payoutNumerators(conditionId, index)`, `getOutcomeSlotCount(conditionId)`
   - Generic; not Polymarket-specific (will be reusable for any Gnosis CTF deployment)
   - Tests: position ID derivation against known Polymarket market; mocked Multicall3 batch

3. **`feat(polymarket): add PolymarketClient (Gamma + CLOB)`** ✅
   - `app/services/polymarket_client.rb`
   - Two `Faraday` connections (separate `BASE_GAMMA` + `BASE_CLOB` constants, since rate-limit behavior differs)
   - Public methods (Phase A subset):
     - `.fetch_market_by_slug(slug)` → `Market` struct (gamma `/markets/slug/{slug}`)
     - `.fetch_market_by_condition_id(condition_id)` → `Market` struct (CLOB `/markets/{cid}` — leaner, has `tokens[]` with explicit outcome labels)
   - Solid Cache: 5 min TTL for market metadata
   - Parses JSON-encoded string fields (`outcomes`, `outcomePrices`, `clobTokenIds`) into Ruby arrays
   - Treats prices as strings → `BigDecimal`, never `Float`
   - `Market` struct fields: `condition_id`, `question_id`, `slug`, `question`, `outcomes`, `clob_token_ids`, `end_date`, `active`, `closed`, `neg_risk`, `volume_num`, `accepting_orders`, `enable_order_book`
   - Tests: VCR cassettes; covers active binary market, closed/resolved market, neg-risk market, slug-not-found 404

4. **`feat(polymarket): add ResolutionReader`** ✅
   - `app/services/polymarket/resolution_reader.rb`
   - Input: `condition_id`, optional `uma_adapter_address` (for in-flight question state)
   - Returns: `{state: :unresolved | :resolved, payouts: [Numeric, Numeric] | nil, payout_denominator: Integer | nil}`
   - State determination: read `ConditionalTokens.payoutDenominator(condition_id)` — non-zero ⇒ `:resolved`
   - Resolved payouts: read `payoutNumerators(condition_id, 0)` and `payoutNumerators(condition_id, 1)` (for binary; loop for neg-risk)
   - **Defer to Phase A.5**: in-flight UMA proposal state (proposed/disputed) — needs OOv2 lookup which adds complexity; ship `:unresolved` as a single bucket first, refine later
   - Tests: mocked Multicall3 batch returning each state

5. **`feat(polymarket): add MarketFetcher orchestrator`** ✅
   - `app/services/polymarket/market_fetcher.rb`
   - Input: `slug` OR `condition_id`
   - Output: composite struct combining `PolymarketClient` metadata + `ResolutionReader` state + on-chain ERC-1155 total supplies (volume proxy)
   - Slug → uses gamma; condition_id → uses CLOB; either way ends with the same struct shape
   - 60s Solid Cache for the composite result (separate from underlying API caches)
   - Tests: integration-style with mocked client + mocked reader

6. **`feat(polymarket): add PositionFetcher`** ✅
   - `app/services/polymarket/position_fetcher.rb`
   - Input: `address`, `condition_ids: [..]`
   - Per condition_id: fetch market metadata (for collateral + outcomes), derive YES/NO position IDs, Multicall3-batch `balanceOf` reads
   - Output: `[{condition_id:, slug:, outcomes: [{name:, position_id:, balance:, redeemable:}]}]`
   - `redeemable` = resolved && payoutNumerator for that index > 0 && balance > 0
   - Tests: mocked Multicall3 + client

7. **`feat(adapter): add PolymarketAdapter + view partials`** ✅
   - `app/services/protocol_adapters/polymarket_adapter.rb`
   - `matches?` checks `contract.chain.slug == "polygon"` && address in allow-list (use a `Set` constant)
   - `type_tag = "polymarket_{role}"` where role is one of `exchange|ctf|uma_adapter|neg_risk_adapter` — derived from address
   - `template_partial` returns per-role partial path
   - Each panel partial is server-rendered: pulls 3-5 top markets via `PolymarketClient` (gamma `/markets?limit=5&active=true&order=volume_num` style), shows a small table; UMA-adapter panel shows recent resolutions
   - **CTFExchange recently emits `OrderFilled` events on-chain** — reuse `ContractEvents::RecentFetcher` to surface them in the existing "Recent activity" section (already present, no extra work)
   - Add `PolymarketAdapter` to `Base::ADAPTER_NAMES` *before* `UniswapV3Adapter` (priority — Polymarket addresses are explicit; UniswapV3 needs an RPC call to `factory()`)
   - Tests: adapter resolution against each address, view rendering smoke tests

8. **`feat(mcp): add get_polymarket_market tool`** ✅
   - `app/tools/get_polymarket_market_tool.rb`
   - Input: `slug` (preferred) OR `condition_id`
   - Output (Phase A):
     ```ruby
     {
       protocol: "Polymarket",
       slug: "...",
       condition_id: "0x...",
       question: "...",
       outcomes: [{name: "Yes", token_id: "...", on_chain_supply: 12345}, ...],
       neg_risk: false,
       state: :resolved | :unresolved,
       payouts: [1, 0] | nil,
       end_date: "2026-...",
       volume_num: 12345.67,
       links: {
         polymarket_url: "https://polymarket.com/market/...",
         exchange_contract: "https://smarts.md/polymarket-ctf-exchange-v2-polygon"
       }
     }
     ```
   - Tests: mocked fetcher, snapshot of payload shape

9. **`feat(mcp): add get_polymarket_position tool`** ✅
   - `app/tools/get_polymarket_position_tool.rb`
   - Input: `address`, one of `condition_ids: [..]` / `slugs: [..]`
   - Output: array of per-market positions (see PositionFetcher §6)
   - Cap input array at 10 condition_ids to bound Multicall3 batch size
   - Tests: address with balances, address with zero balances, mixed resolved/unresolved markets

10. **`docs: CLAUDE.md — document Polymarket support`** ✅ (see §10)

### Phase B

11. **`feat(polymarket): add CLOB midpoint + best bid/ask`** ✅
    - Extend `PolymarketClient` with `.fetch_midpoint(token_id)`, `.fetch_best_price(token_id, side:)`, batch variants (POST `/midpoints`, POST `/prices`)
    - 30s Solid Cache (prices move fast; longer would be misleading)
    - Handle "no orderbook" responses gracefully (closed markets return error JSON — treat as expected `nil`)

12. **`feat(polymarket): surface live prices in MarketFetcher + MCP tool`** ✅
    - `MarketFetcher` calls CLOB pricing in parallel with on-chain reads for active markets only
    - `get_polymarket_market` output gains:
      ```ruby
      outcomes: [{name: "Yes", token_id: "...", mid_price: 0.74, best_bid: 0.735, best_ask: 0.745, ...}, ...]
      ```
    - All prices as `BigDecimal` → JSON-serialize as string to preserve precision
    - Tests: VCR-cassette for live orderbook; price-parsing edge cases

13. **`feat(adapter): live prices in protocol_adapters/_polymarket_exchange.html.erb`** ✅
    - Add a "Live markets" Turbo Frame on exchange contract show pages, refreshed every 30s
    - Top 5 active markets by volume with mid prices

---

## CLAUDE.md amendment (proposed text)

To be appended to the protocol/adapter section, with cross-references from §"支持的协议" and §"External Integration Layer":

```markdown
### Polymarket（例外说明）

Polymarket 是唯一允许调用 off-chain REST API 的协议适配器。理由：
- Polymarket 是 off-chain order book + on-chain settlement 模型，当前赔率/订单簿只活在
  `clob.polymarket.com` 和 `gamma-api.polymarket.com`，链上拿不到
- "AI agent 查事件市场赔率"是 Smarts 的杀手级 MCP 用例之一，没有它会失去整个协议的展示价值
- 仅限只读 (GET) 请求；下单/交易接口绝对不接（与"不做钱包连接"约束一致）

实现位置：`app/services/polymarket_client.rb`（Faraday + Solid Cache，模板照搬 DefiLlamaClient）。
所有 Polymarket 相关业务逻辑封装在 `app/services/polymarket/*` 命名空间下。

支持的合约（Polygon mainnet）见 `app/services/contract_slugs.rb` 的 `polymarket-*` 条目。
```

The supported-protocols table at the top of CLAUDE.md also gets:

| Month | 协议 | 适配器 |
|---|---|---|
| ... | ... | ... |
| Month 4+ | Polymarket (CTFExchange / NegRiskCtfExchange / ConditionalTokens / UmaCtfAdapter) | PolymarketAdapter |

---

## Test strategy

- **Unit tests** for every service. Mock Multicall3 + PolymarketClient at the service boundary.
- **VCR cassettes** for PolymarketClient. Record one cassette per representative case (active binary, resolved binary, active neg-risk, slug-404, closed market with no orderbook). Cassettes are gitted; refresh via `rm cassette.yml && rerun test` if Polymarket changes API shape.
- **One end-to-end test**: real slug (pick a closed/resolved market so it doesn't drift) → MCP tool → assert all top-level keys present and types correct.
- **CI**: must pass `bin/test` green before any PR review.

---

## Caching policy

| Data | Layer | TTL |
|---|---|---|
| Gamma `/markets/slug/{slug}` | Solid Cache | 5 min |
| CLOB `/markets/{cid}` | Solid Cache | 5 min |
| CLOB `/midpoint`, `/price`, `/books` | Solid Cache | 30 s |
| `ConditionalTokens.payoutDenominator/Numerators` | Solid Cache | 60 s (resolved markets effectively immutable; keep TTL short to catch settlement transitions) |
| `ConditionalTokens.balanceOf` | Solid Cache | 30 s (positions can move) |
| `MarketFetcher` composite | Solid Cache | 30 s (includes live CLOB prices) |
| Adapter panel partial | Rails fragment | 30 s |

Cache keys follow the existing convention: `polymarket:{layer}:{chain}:{identifier}`.

---

## Acceptance criteria

### Phase A
- [x] `smarts.md/polymarket-ctf-exchange-v2-polygon` (and the other 8 slugs) resolves and renders a Polymarket-themed panel
- [x] `smarts.md/polygon/0x4bfb...982E` redirects to the canonical slug page (existing behavior — confirms slug registration works)
- [x] MCP tool: `get_polymarket_market(slug: "<a known active binary market>")` returns payload with `state`, `outcomes`, token IDs, and derived CTF position IDs
- [x] MCP tool: `get_polymarket_market(slug: "<a known resolved binary market>")` returns `state == :resolved` and `payouts` array when on-chain state is resolved
- [x] MCP tool: `get_polymarket_position(address: ..., condition_ids: ["0x..."])` returns per-outcome balances and redeemable flags
- [x] All tests green (`bin/rails test`)
- [x] CLAUDE.md amendment merged

### Phase B
- [x] `get_polymarket_market` for an active market now includes `mid_price`, `best_bid`, `best_ask` per outcome
- [x] Closed markets return `nil` for those fields without raising errors
- [x] All prices are JSON strings (BigDecimal-backed; no Float serialization)
- [x] Exchange contract show page has a live Turbo Frame showing top-5 mainstream markets with 30s refresh

### Hard NOs (out of scope, even if convenient)
- ❌ Placing orders / signing trades — read-only forever
- ❌ Auto-discovery of all condition_ids for an address (defer to data-api integration)
- ❌ Historical price charts (just current state)
- ❌ Polymarket on chains other than Polygon (they had a brief mUSDC era on other chains; not supported here)
- ❌ Hardcoding UMA OOv2 address — resolve via adapter's `oracle()` getter

---

## Open questions before kickoff

1. **Should Phase A surface in-flight UMA proposal state** (proposed-but-not-settled, disputed) via OOv2 lookup, or is "unresolved" as a single bucket fine for v1? Adding OOv2 doubles the on-chain read surface and pulls in another contract — feels like a Phase B+ extension.
2. **`get_polymarket_position` discovery**: keeping it strictly explicit (caller passes condition_ids) means MCP agents have to know what to ask about. Acceptable tradeoff for v1, or worth a Phase B addition that scans Polymarket data-api for an address's known markets?
3. **CTF V2 collateral**: research surfaced that V2 uses "Polymarket USD" (not USDC.e). Need to confirm what that token is on-chain before adapter ships — likely just read `getCollateral()` at runtime, but worth a sanity check.
4. **Branch rename?** `feat/polymarket-v1` allows Phase B to be a sibling `feat/polymarket-v2`. Or keep both phases in one branch and ship two PRs. I'd default to one branch, two PRs, but flexible.

---

## Estimated effort (single-developer, focused)

| Phase A step | Estimate |
|---|---|
| 1. Slugs | 30 min |
| 2. ConditionalTokensReader | 3 hr |
| 3. PolymarketClient | 4 hr (incl. cassettes) |
| 4. ResolutionReader | 2 hr |
| 5. MarketFetcher | 3 hr |
| 6. PositionFetcher | 2 hr |
| 7. Adapter + 4 view partials | 5 hr |
| 8. get_polymarket_market tool | 2 hr |
| 9. get_polymarket_position tool | 1.5 hr |
| 10. CLAUDE.md | 30 min |
| **Phase A total** | **~24 hr (3 focused days)** |
| Phase B steps 11-13 | ~6 hr (1 day) |

Real calendar time is usually 1.5-2× given context switches.
