---
created: 2026-04-21T07:27:53.501Z
title: Expose contract source files via MCP tool
area: general
files:
  - app/tools/get_contract_info_tool.rb
  - app/tools/get_uniswap_v3_pool_tool.rb
  - app/helpers/source_code_helper.rb
  - app/views/contracts/_source.html.erb
  - config/initializers/fast_mcp.rb
---

## Problem

Verified contracts on smarts often ship many source files (AAVE token `0x7Fc6…DaE9` has 19 `.sol` files). The web UI renders them as sub-tabs via `SourceCodeHelper#source_files`, but there's no MCP way for an AI agent (Claude Code, Cursor, etc.) to fetch that same source. Today's MCP tools (`get_contract_info`, `get_uniswap_v3_pool`, `read_contract_state`) only return metadata / live state, so an agent analyzing a contract has to bounce out to Etherscan.

Fits the AI-native angle in CLAUDE.md: MCP should expose both docs and the underlying source so agents can read what functions actually do when the doc is thin or wrong.

## Solution

Add `GetContractSourceTool` at `app/tools/get_contract_source_tool.rb`.

Tool shape (discussed with user):

```
get_contract_source(chain:, address:, file: nil, search: nil)
```

- No `file` → return file index: `[{path:, bytes:}, …]` plus totals. Agent picks what to read.
- `file: "AaveToken.sol"` → return that file's `content`.
- `search: "transfer"` → return a grep-like match list across files (path + line + snippet), bounded (e.g. max 50 hits). Saves agents from slurping 20 files just to find one function.

Implementation is mostly plumbing — the hard part is already done:

1. Load `Contract.find_by!(chain:, address:)`.
2. Reuse `SourceCodeHelper#source_files(contract.source_code)` to split into `[{path:, content:}]`. Already handles the three Etherscan shapes (plain, JSON, standard-input JSON).
3. Dispatch by argument combination (index / single file / search).
4. Size guardrails: clamp single-file response (e.g. warn or truncate if >100KB); cap `search` hits.
5. Register automatically via `ApplicationTool.descendants` (per `config/initializers/fast_mcp.rb:34`).

Open decisions:
- Return raw source as a single string field, or structured `{path, content, lines}`? Probably string for single-file reads (cheaper tokens), structured for search.
- Include compiler version / optimizer settings in the index response? Probably yes — cheap and often relevant to an agent.
- Should proxies return proxy source, implementation source, or both? Depends on proxy-ABI-resolution todo landing first; for MVP return whatever's indexed on the requested address.
