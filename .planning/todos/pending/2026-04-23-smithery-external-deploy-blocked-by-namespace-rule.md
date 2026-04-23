---
created: 2026-04-23T13:13:45.247Z
title: Smithery external deploy blocked by namespace rule
area: general
files:
  - smithery.yaml:1
  - .planning/todos/pending/2026-04-23-ai-native-discovery-audit-and-backlog.md
---

## Problem

Smithery's publish UI requires a **namespace** that is 3–39 characters, starts with a **letter**, and contains only letters, numbers, hyphens, or underscores.

Bob's default Smithery handle is `7777` (matches his `7777@hey.com` email). It fails validation at `smithery.ai/publish` because it starts with a digit — the `Continue` button stays disabled.

Captured 2026-04-23 during Smithery external deploy attempt after PR #22 merged the metadata-only `smithery.yaml`.

### Context

This is the post-merge follow-up for PR #22 (`feat(discovery): llms.txt, AI crawler allowlist, Smithery metadata fix`). The PR itself is landed; what's blocked is the one-line CLI step that would actually register smarts.md in the Smithery registry:

```
npx -y @smithery/cli@latest mcp deploy \
  --name <namespace>/smarts \
  --url https://smarts.md/mcp/sse
```

Parent todo: `2026-04-23-ai-native-discovery-audit-and-backlog.md` — this is the "P1 item #2" post-merge action.

## Solution

Pick one:

- **A. Create a Smithery org/namespace that starts with a letter.** Candidates: `defifund` (matches the GitHub org), `smarts`, `chain-dev` (matches chain.dev parent brand). Needs the Smithery org creation flow (probably `smithery.ai/new-organization` or a CLI command — check `npx @smithery/cli@latest namespace --help`).
- **B. Change personal account handle** if Smithery allows renaming the user slug. Less certain it's possible.

Once unblocked, run the deploy command above, then verify:
```
curl -s "https://smithery.ai/server/<namespace>/smarts"   # page should 200
```

## Reconsider if

- Smithery loosens the namespace rule to allow digit-starting slugs (seems unlikely — this is the same convention as npm / GitHub orgs).
- Glama listing (separate directory) ends up driving most traffic, making the Smithery registration less urgent.
