---
created: 2026-04-25T12:34:50.700Z
title: Polymarket 链上信息解读 adapter
area: general
files: []
---

## Problem

Polymarket 是一个核心 DeFi 协议（预测市场类，与现有 DEX / Lending 类目不同）。
目前 MVP 路线主打 Uniswap V3、Aave V3、ERC-20 通用适配器，没有覆盖
prediction market 这个垂直。但 Polymarket 用户量、AI 关注度都很高
（"AI agent 查询某事件赔率" 是天然的 MCP use case），值得评估纳入。

需要回答的问题：
- Polymarket 主链：Polygon PoS（chain_id 137，已在 MVP 链支持范围内）
  和 Polymarket 自家 L2 的现状（如已迁移则需要扩链）
- 核心合约结构：ConditionalTokens、FixedProductMarketMaker、
  CTF Exchange、UMA optimistic oracle 集成
- 链上能读出什么：每个 market 的 question、outcome、当前赔率、
  流动性、resolution 状态、UMA dispute 状态
- 与 Uniswap V3 等 AMM 的差异：CPMM + binary outcome + oracle
  resolution，函数级文档 + live state 的展示方式不同
- AI / MCP 角度的卖点：让 Claude / GPT 通过 MCP 查询任意 Polymarket
  市场的当前赔率和 resolution 状态——这是 Mintlify 类静态文档做不到的

## Solution

TBD —— 先做调研：
1. 列出 Polymarket 在 Polygon 上的核心合约地址（CTF、Exchange、UMA adapter）
2. 跑一个原型：用现有 EtherscanClient + ChainReader 拉一个活跃 market 的
   ABI 和 live state，看看通用 GenericErc20Adapter / 现有渲染管线
   能覆盖到什么程度
3. 评估是否值得做专门的 `PolymarketAdapter`，还是先靠通用渲染
   + AI 富化覆盖
4. 如果做专门 adapter：放在 Month 3+（Aave V3 之后），还是替换
   roadmap 里某一项，需要重新讨论优先级
