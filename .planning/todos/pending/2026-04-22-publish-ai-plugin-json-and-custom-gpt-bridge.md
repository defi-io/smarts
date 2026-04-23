---
created: 2026-04-22T22:00:00.000Z
title: Publish ai-plugin.json and build Custom GPT bridge
area: general
files:
  - app/controllers/marketing_controller.rb
  - config/routes.rb
  - public/.well-known/ai-plugin.json (new)
---

## Problem

ChatGPT doesn't speak MCP natively (as of 2026-04). Until it does, users who want to query smarts contracts from inside ChatGPT have no clean path. The mcp.smarts.md docs page politely says "Coming when OpenAI stabilizes MCP support" — that's a real gap in distribution.

Also: `.well-known/ai-plugin.json` is OpenAI's Custom GPT / plugin discovery convention (OpenAPI-based, NOT MCP-shaped). Publishing one today would let a Custom GPT pick up our API contract without manual config.

## Solution

Two-part effort:

1. **Publish `/.well-known/ai-plugin.json`** — OpenAI plugin manifest pointing at a REST/OpenAPI spec of our MCP tools' functionality. Not the same as the MCP manifest; different protocol, different shape.

2. **Build a Custom GPT** — named "Smart Contract Docs" or similar, configured via ChatGPT's Custom GPT UI to use the `ai-plugin.json`. OpenAPI endpoints would mirror the five MCP tools but speak REST.

## Why not bundle with the MCP work

- MCP manifest (`.well-known/mcp.json`) and ai-plugin.json are different protocols. Mixing them is confusing.
- Custom GPT requires deliberate marketing + OpenAI vetting. Not a drop-in.
- This is a separate distribution channel with its own maintenance cost.

## Reconsider if

- OpenAI announces native MCP support in ChatGPT → drop this entirely
- User traffic from ChatGPT becomes meaningful enough to justify the maintenance
- We have a REST API already (we don't — MCP + web are the two surfaces today)

## Notes

- The dismissive one-liner on mcp.smarts.md about ChatGPT is our current stance. When we do this work, update that line to link to the Custom GPT.
- Avoid duplicating tool logic — any REST handlers should thinly wrap `app/tools/*`, not reimplement.
