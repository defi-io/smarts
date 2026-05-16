---
created: 2026-05-16T02:30:00Z
title: get_erc20_info silently fails on USDT-style tokens (one-failure-poisons-batch)
area: mcp
files:
  - app/services/protocol_adapters/generic_erc20_adapter.rb
  - app/tools/get_erc20_info_tool.rb
  - test/services/protocol_adapters/generic_erc20_adapter_test.rb
---

## Problem

`get_erc20_info slug=usdt-eth` returns `{"error":"could not read token metadata"}`, yet the underlying functions all work when called individually:

| Tool call | Result |
|---|---|
| `read_contract_state` `symbol` | ✅ `"USDT"` |
| `read_contract_state` `decimals` | ✅ `6` |
| `read_contract_state` `owner` | ✅ `0xc6cde7c39eb2f0f0095f41570af89efc2c1ea828` |
| `read_contract_state` `paused` | ✅ `false` |
| `get_erc20_info slug=usdt-eth` | ❌ `"could not read token metadata"` |

So the tool is asking the right contract the right questions, and the chain answers them — but the **batched** path fails.

### Root cause hypothesis

`GenericErc20Adapter#read_onchain_state` (app/services/protocol_adapters/generic_erc20_adapter.rb:162) bundles the 4 core ERC-20 reads (`name`, `symbol`, `decimals`, `totalSupply`) plus optional admin probes into a **single Multicall3 `aggregate3` call**. If any call in the batch raises during decoding, the whole multicall path falls into the `rescue StandardError` at line 192 and returns `{ name: nil, symbol: nil, decimals: nil, total_supply: nil }`. The tool then sees `symbol.blank?` and emits the generic error message.

USDT's `name()` returns a `bytes32` *typed* as `string` in the ABI — Solidity 0.4.18 quirk. Eth gem's `Eth::Abi.decode(["string"], …)` on USDT's raw bytes either raises (wrong dynamic offset) or returns garbage that breaks downstream `force_encoding(UTF_8)`. Whichever it is, one bad call kills the whole batch.

The ADMIN probe code (`admin_functions_in_abi`) is conservative (filters by exact `outputs[0].type` match), but the **core ABI list is hard-coded** — `ERC20_NAME` uses `"string"` regardless of what the contract actually declares.

## Solution

Two-part fix:

1. **Read the actual ABI types from `contract.abi`** for the core fields, instead of using the hard-coded `ERC20_NAME` / `ERC20_SYMBOL` shapes. Falls back to the standard types only if the function is missing from the ABI (some unverified-but-classified path).

2. **Isolate per-field failures** so one decode error doesn't blank out the whole panel. The Multicall3 `Result` already exposes `success` per call; we use it for admin probes (line 187) but not for the core reads. Mirror that pattern: `name` failing surfaces as `name: nil` while `symbol` and `decimals` still come through.

Then the tool's `symbol.blank? || decimals.nil?` guard only trips when *both* are genuinely missing — not when `name` happens to decode weird.

### Test fixture

Add a USDT-shaped fixture to `test/services/protocol_adapters/generic_erc20_adapter_test.rb`:
- ABI declares `name()` returning `string` (per ABI)
- Multicall stub returns 32 ASCII bytes with no length prefix for `name` (mimics USDT's bytes32-as-string quirk) → triggers decode failure
- Assert: panel still returns symbol, decimals, totalSupply correctly
- Assert: `name` is nil, not an exception

### Bonus follow-up (separate PR)

The admin probe list (`ADMIN_STATUS_FUNCTIONS`, `ADMIN_ROLE_FUNCTIONS`) was modeled on **Circle FiatToken** (owner / masterMinter / pauser / blacklister / rescuer). USDT's TetherToken uses a different shape: single `owner` with `addBlackList(address)` / `removeBlackList(address)` / `pause()` / `deprecate(...)` / `issue(...)` / `redeem(...)` powers.

Result: `get_erc20_info` for USDT would correctly surface `owner` and `paused` (already in the list), but would **miss the framing that this single owner can blacklist, pause, deprecate, AND mint** — a critical distinction from USDC's split-key model.

Possible: add a `governance_model` field to the response that names the pattern detected (`"circle_fiat_token"` / `"tether_token"` / `"unknown"`) so AI consumers know which mental model to apply.

## Priority

**Medium-high.** USDT is the 3rd-largest ERC-20 by market cap (~$140B) and the single most-traded stablecoin on every chain we support. Silent failure on it makes `get_erc20_info` look broken on a flagship example, and it's referenced in the landing page's `MCP_EXAMPLE_QUERIES` (`"Get the total supply of USDT on Arbitrum"`).

Fix size: ~30 lines in adapter + 1 fixture + 1-2 tests. ≤45 min.
