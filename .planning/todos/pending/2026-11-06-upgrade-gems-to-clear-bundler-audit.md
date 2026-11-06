---
created: 2026-11-06T16:31:55.000Z
title: Upgrade gems to clear bundler-audit (activestorage Critical, puma/rack High)
area: security
files:
  - Gemfile
  - Gemfile.lock
  - .github/workflows/ci.yml
---

## Problem

CI `scan_ruby` (bin/bundler-audit) fails on master. It went unnoticed because CI had been broken
at "Set up Ruby" (ubuntu-latest became 26.04, no Ruby 3.4.8); runners are pinned to ubuntu-24.04
since #96, so the audit now actually runs. smarts is public, so this is the priority one.

Advisories seen 2026-11-06 (count by gem/criticality):
- **Critical**: activestorage
- **High**: actionpack x2, activestorage, activesupport, concurrent-ruby, erb, faraday, mcp, net-ssh x2,
  oauth, puma x2, rack, ruby_llm x3, rubyzip, websocket-driver
- Medium/Low/Unknown: actionview, actionmailbox, addressable, crass, json, loofah, mail, msgpack,
  net-imap, nokogiri (many), rails-html-sanitizer

## Solution

1. Branch off master, `bundle update --conservative rails puma rack nokogiri ...`; likely Rails
   8.1.3 -> latest 8.1.x patch. Check mcp / ruby_llm separately (API changes possible).
2. `bin/bundler-audit` locally until clean; ignore only with a written reason in
   config/bundler-audit.yml.
3. `bin/rails test` + CI green, then PR, merge, `bin/kamal deploy` (needs `op signin`).
4. Smoke-check smarts.md and mcp.smarts.md after deploy.
