# Polymarket 蓝海功能：Smarts 差异化切入点

_Created: 2026-05-20_
_Source: 竞品调研 170+ Polymarket 第三方工具后的缺口分析_

---

## 背景

Polymarket 生态已有 170+ 第三方工具（鲸鱼追踪、排行榜、copy trading、AI 信号等），
赔率/价格/交易者分析赛道极度红海。Smarts 不应进入这些领域竞争。

Smarts 的独特定位：**Polymarket 合约的透明层**——所有现有工具把合约当黑盒，
只包装 Gamma/CLOB/Data API。没有人从链上合约层面提供洞察。

---

## 优先级 1：UMA 争议 / Resolution 审计

**需求场景**：每次争议市场结算都是 Twitter 热搜（如 missing pilot 事件），
交易者急需从链上验证"这个市场到底怎么结算的"。

**当前状态**：`UmaActivity` 服务 + `ResolutionReader` 已有基础设施。

**要做的事**：
- [x] 将 UMA dispute 状态暴露为独立 MCP tool（`get_polymarket_resolution`）
- [x] 在 UMA adapter 合约页面展示 dispute 时间线（question → propose → dispute → settle）
- [x] 链上 `ConditionResolution` 事件 vs Gamma API 结果的一致性校验
- [x] 争议中的市场高亮提示（在 `/polymarket` 聚合页）

**竞争**：零竞品。没有任何工具从链上合约层面提供 resolution 审计。

---

## 优先级 2：合约治理 / Admin 风险透明度

**需求场景**：交易者需要知道"谁能 pause 交易所？最近有没有 proxy 升级？"

**当前状态**：`GovernanceTimeline` + `AdminRisk::Profiler` 已是 Smarts 核心能力。

**要做的事**：
- [x] 确保所有 Polymarket curated slugs 的 governance timeline 完整扫描
- [x] 在 exchange/CTF/UMA adapter 合约页面突出显示 admin 权限面板
- [x] MCP tool 支持查询 Polymarket 合约的 admin 风险（复用现有 `get_governance_timeline`）

**竞争**：零竞品。170+ 工具中无一提供合约 admin 风险分析。

---

## 优先级 3：合约级 MCP（vs 纯 API wrapper）

**需求场景**：AI agent 需要从链上验证数据，而非只包装 REST API。

**现有差异**：Sim.ai、The Graph MCP 都是 Gamma/CLOB API wrapper。
Smarts MCP 直接读链上 view 函数 + 解码事件。

**要做的事**：
- [x] 新增 `get_polymarket_resolution` tool（链上 resolution state + payout 验证）
- [x] 增强 `read_contract_state` 对 Polymarket 合约的文档/示例
- [x] 在 MCP docs 页面突出"链上原生 vs API wrapper"的差异

**竞争**：低竞争。现有 MCP 集成均为 API 包装。

---

## 优先级 4：合约源码级文档

**需求场景**：开发者想理解 V1 vs V2 区别、NegRiskAdapter 机制、
collateral adapter 的 USDC→USDC.e 转换逻辑。

**要做的事**：
- [x] 为 Polymarket 核心合约生成 AI enriched 源码文档
- [x] 在合约页面添加"Architecture" section，解释合约间关系
- [x] 关键函数的 NatSpec 增强（Polymarket context overlay）

**竞争**：零竞品。所有工具把合约当黑盒。

---

## 红海（不做）

| 类别 | 理由 |
|---|---|
| 实时赔率/价格展示 | 官方 + Polysights + 数十个竞品 |
| 鲸鱼追踪/alert | PolyTrack, Polywhaler, PolyFire 等 |
| 交易者排行/PnL | Polymarket Analytics, HashDive 等 |
| Copy Trading | Olympus, Ride, Polycule 等 |
| OHLCV/K线图 | The Graph, Dune, CLOB API |
| AI 预测信号 | Polysights, Polyfactual 等 |

> **原则**：不跟 170+ 工具抢 off-chain 数据层，只做链上合约透明层。

---

## 已完成的相关工作

- [x] MCP tool: `get_polymarket_market`（market metadata + prices）
- [x] MCP tool: `get_polymarket_position`（wallet CTF balances）
- [x] `PolymarketAdapter` 全 curated family 角色覆盖（ctf_exchange / neg_risk_exchange / ctf / uma_adapter / neg_risk_adapter / pUSD / collateral adapters / neg_risk_operator）
- [x] `ExchangeActivity` / `CtfActivity` / `UmaActivity` / `NegRiskActivity` 服务
- [x] `ResolutionReader` 链上 resolution 读取
- [x] `/polymarket` 市场聚合入口页（Turbo Frame 30s 刷新）
- [x] MCP tool 动态选择 CTF Exchange vs Neg Risk Exchange 链接（基于 neg_risk 字段）
- [x] Polymarket Architecture section + same-ABI/different-path exchange comparison
- [x] Polymarket HTML/Markdown key function and event context overlay
- [x] Polymarket AI enrichment prompt includes adapter role, architecture flow, and exchange distinction
