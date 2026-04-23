---
created: 2026-04-23T15:00:00.000Z
title: Brand-overlay mechanism for curated display name
area: general
files:
  - app/helpers/contracts_helper.rb
  - app/controllers/marketing_controller.rb
  - app/services/contract_slugs.rb
---

## Problem

Polygon's MATIC → POL 2024 rebrand exposed a gap: when on-chain `name()` / `symbol()` change but the market's mental model lags (or diverges), the on-chain truth may not be what users want to see as the primary label.

**Current state after PR #26 + #27:**

- `contract_display_name` (`app/helpers/contracts_helper.rb`) prefers on-chain `name()` → `symbol()` → `contract.name` → "Unknown Contract".
- `FEATURED` (`app/controllers/marketing_controller.rb`) hardcodes display symbol/name for curated contracts — but only the homepage cards use it, the contract page itself doesn't.
- `ContractSlugs` (`app/services/contract_slugs.rb`) holds slugs whose path segments can outlive their brand (`/wmatic-polygon` now points at a contract whose on-chain symbol is `WPOL`).

The pre-rebrand `WMATIC` references were patched in PR #27, but the underlying mechanism — a way to say "for this (chain, address), override the auto-resolved display name" — doesn't exist. Next rebrand will require the same manual three-file sweep.

## Solution

Introduce a curated override layer keyed by `(chain, address)`:

```ruby
module ContractBrandOverrides
  MAP = {
    ["polygon", "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270"] => {
      name:        "Wrapped POL",
      symbol:      "WPOL",
      legacy_name: "WMATIC"           # optional — for "also known as" badges / SEO
    }
    # future entries here when a second case emerges
  }.freeze

  def self.lookup(contract)
    MAP[[contract.chain.slug, contract.address.downcase]]
  end
end
```

Plug into `contract_display_name` as the top of the fallback chain:

```ruby
def contract_display_name
  ContractBrandOverrides.lookup(@contract)&.dig(:name) ||
    live_value("name()").to_s.presence ||
    live_value("symbol()").to_s.presence ||
    @contract&.name.presence ||
    "Unknown Contract"
end
```

Could also feed `FEATURED` off the same map to eliminate the duplicated WPOL entry.

## Why defer

- **YAGNI.** We have exactly one case today (WPOL), already handled by fixing the on-chain truth path plus FEATURED card.
- **Premature abstraction risk.** The right shape of the override is unclear until we see 2–3 real cases. Is it always `name` + `symbol`? Is there a `legacy_name` for SEO? Per-chain or per-address? Let the real examples pin down the schema.

## Reconsider if

- A second rebrand case surfaces (another token, another chain — won't be long in crypto).
- Users report confusion on a specific contract's displayed name.
- We want an official "Smarts display name" that diverges from on-chain for legitimate reasons — e.g. proxy implementations with meaningless names where even `symbol()` fallback isn't a good answer.
- We want to power an "Also known as: WMATIC" SEO badge (the `legacy_name` field above).
