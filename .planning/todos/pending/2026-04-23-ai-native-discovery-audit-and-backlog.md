---
created: 2026-04-23T11:23:18.299Z
title: AI-native discovery audit and backlog
area: general
files:
  - public/robots.txt
  - public/llms.txt (new)
  - app/views/layouts/application.html.erb
  - app/views/contracts/show.html.erb
  - app/controllers/contracts_controller.rb
  - config/routes.rb:32
---

## Problem

Goal: let Claude / AI agents discover and use smarts.md without manual setup.

Audited current state against "how would Claude find smarts" on 2026-04-23 with Claude. Core finding: **Claude does not auto-discover or auto-install MCP servers.** The realistic discovery paths are:

1. **SEO + WebFetch hitting contract doc pages** — primary traffic, users ask Claude about a contract, Claude web-searches, lands on `smarts.md/eth/0x...`, uses content to answer.
2. **Human developers finding us on an MCP directory** and manually configuring `mcp.smarts.md` in their Claude Code / client.

"One MCP endpoint per contract" is a product narrative, not a discovery mechanism — clients will never auto-install per-contract endpoints.

### Audit (2026-04-23 audit → 2026-04-23 end-of-day)

| Item | Status |
|---|---|
| MCP server `/mcp/sse` | shipped (pre-audit) |
| `.well-known/mcp.json` manifest | shipped (pre-audit) |
| Smithery directory | metadata.yaml fixed PR #22; **external deploy BLOCKED** — see sibling todo `smithery-external-deploy-blocked-by-namespace-rule` |
| Per-contract MCP reference card | shipped (pre-audit) |
| `llms.txt` | ✅ done (PR #22) |
| OpenGraph / JSON-LD / Twitter meta | ✅ done (PRs #23, #24, #25) |
| BreadcrumbList + WebSite SearchAction JSON-LD | ✅ done (PR #24) |
| 1200×630 OG card PNG | ✅ done (PR #25) |
| Brand-first display name (on-chain name(), adapter display_name) | ✅ done (PRs #26, #29) |
| WMATIC → WPOL rebrand cleanup + slug alias | ✅ done (PRs #27, #28) |
| Markdown variant of contract pages (`/eth/0x....md`) | ✅ done (PR #30) |
| Mobile layout fixes (overflow, padding, wordmark) | ✅ done (PR #31) |
| `robots.txt` AI crawler allowlist | ✅ done (PR #22) + Cloudflare managed robots.txt disabled |
| `sitemap.xml` | ⏳ NOT STARTED |
| Glama listing | ⏳ NOT STARTED (manual submission by Bob) |
| Official MCP Registry | ⏳ NOT STARTED (PR to `modelcontextprotocol/servers` by Bob) |

## Solution

Prioritized backlog — P1/P2/P4-P6 done today across 10 PRs. Remaining open work:

### P1 — done

1. ✅ `public/llms.txt` (PR #22)
2. ⏳ Submit to Glama (`glama.ai/mcp/servers`) — **manual, still pending**
3. ✅ `robots.txt` AI crawler allowlist (PR #22)

### P2 — partially done

4. ✅ OpenGraph + JSON-LD on contract pages (PRs #23/#24/#25/#26/#29)
5. ⏳ Dynamic sitemap — **still pending**. Options: `sitemap_generator` gem (needs approval per CLAUDE.md) or hand-roll a `GET /sitemap.xml` controller. List all known Contracts updated daily.
6. ✅ `.md` variant of contract pages (PR #30)

### P3 — still pending

7. ⏳ Submit to official MCP Registry (PR to `github.com/modelcontextprotocol/servers`) — **manual by Bob**.

### Explicitly not doing

- Cursor Directory — wrong fit (their spec targets Cursor runtime, our dynamic per-contract model doesn't map).
- MCP.so — issue-based, static display, low ROI compared to Glama.
- Large-scale SEO content — wait until Month 2 when protocol coverage broadens.

## Reconsider if

- MCP protocol adds auto-discovery (e.g., `.well-known/mcp-servers` client convention) — then per-contract endpoints become addressable and the whole calculus changes.
- Anthropic / OpenAI ship native "fetch MCP server from URL" in their clients — same effect.
- Traffic analytics show a different primary discovery path than SEO + directory.
