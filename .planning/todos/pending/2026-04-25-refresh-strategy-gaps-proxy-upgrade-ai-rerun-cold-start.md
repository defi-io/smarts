---
created: 2026-04-25T13:03:07.141Z
title: 数据更新策略缺口 — proxy 升级、AI 重跑、冷启动
area: general
files:
  - app/controllers/contracts_controller.rb:13-19
  - app/controllers/contracts_controller.rb:88-95
  - app/services/etherscan_client.rb
  - app/services/contract_document/ai_enricher.rb
  - config/recurring.yml
---

## Problem

2026-04-25 审计当前数据刷新策略时发现，目前完全 lazy / request-driven，
没有任何后台主动刷新合约的任务（`config/recurring.yml` 只有 SolidQueue
GC）。多个会直接影响用户体验的缺口：

### 缺口 1: ABI / 源码事实上永不过期
- `EtherscanClient` 自身没有 `Rails.cache.fetch`
- `ContractsController#show` 触发条件是 `Contract` 不存在 或 `abi.blank?`
- 一旦入库就再也不重抓 → **proxy 升级、合约重新验证后用户看到的是旧版**
- CLAUDE.md 缓存表声称"30 天 Solid Cache"，与实现不一致

### 缺口 2: AI enrichment 单次生成
- `AiEnricher` cache key 是 `abi_hash + prompt_version + fn_signature`，
  bump prompt_version 理论上会 cache miss
- 但 controller trigger 看的是 `ai_natspec.blank?`，已经写过的 contract
  即使 prompt 改进了也不会重跑
- 影响：我们改进 prompt 后存量合约文档不会变好

### 缺口 3: 冷启动同步延迟
- 新合约首次访问，Etherscan API 同步阻塞 controller，页面 2-5s 才渲染
- 失败时整个页面渲染失败（虽有 rescue，但用户体验差）

### 缺口 4: live 数据无新鲜度提示
- view 函数值最长可能是 60s 前的快照
- 页面无 "as of block X / Y seconds ago" 指示
- 用户不知道看到的是不是最新

### 缺口 5: 热合约冷缓存
- Top 50 协议无预热机制
- 访问者间隔 >60s 时，每个访问者都要付 RPC 成本
- 体感"为什么打开 Uniswap USDC pool 还要转 1 秒"

### 缺口 6: 文档幽灵存在
- CLAUDE.md 提到的 `RefreshContractJob` / `WarmupCacheJob` 实际不存在

## Solution

按用户体验影响排序的解决思路（详见对话中分析）：

**P0 — 影响正确性，必修**
1. **Proxy upgrade 检测**：每次访问已存在合约，异步触发轻量级
   `eth_getStorageAt` 检查 EIP-1967 implementation slot；变了 → enqueue
   refresh job 重抓 ABI。也可以基于事件订阅（Upgraded(address)）但
   订阅成本大，不如 lazy 检测
2. **AI enrichment 重跑机制**：trigger 改成"如果 contract.prompt_version
   < CURRENT_PROMPT_VERSION 则重跑"，不再只看 ai_natspec 是否存在

**P1 — 显著影响体感**
3. **新合约冷启动渐进式渲染**：
   - 第一次访问立刻返回带占位的 Turbo Frame 骨架（"Fetching from Etherscan..."）
   - Etherscan + ChainReader 异步执行，完成后 turbo_stream broadcast 替换
   - 类似 enrich AI job 的模式
4. **live 数据新鲜度标记**：
   - 在每个 live value 旁显示 "Block #N · 12s ago"
   - block number 已经在 `ChainReader::ViewCaller` 返回值里有

**P2 — 锦上添花**
5. **Top N 预热 Job**：定时（5min）后台读取一份白名单合约的 panel data，
   保持 60s 缓存常热，避免冷访问者付费
6. **CLAUDE.md 缓存表与实现对齐**（要么改 doc，要么补实现）

每一条都可以做成独立 phase 或独立 todo 拆分实施。先做 P0 两条，
proxy 检测尤其重要——目前文档可能在向用户撒谎（展示已升级合约的旧 ABI）。
