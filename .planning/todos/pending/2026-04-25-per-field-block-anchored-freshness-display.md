---
created: 2026-04-25T14:09:20.668Z
title: 按字段显示 block-anchored 新鲜度（取代页面级时间戳）
area: ui
files:
  - app/services/chain_reader/multicall3_client.rb
  - app/services/chain_reader/view_caller.rb
  - app/services/chain_reader/single_caller.rb
  - app/views/contracts/show.html.erb
---

## Problem

当前页面**完全没有**新鲜度提示。用户看到的 view 函数值实际可能落后链端
0-72s（Ethereum：出块 0-12s + Solid Cache 0-60s），但页面上看不出来——
看起来像静态文档，与 Mintlify 没有视觉区别。

直觉上的解法是加个"23s ago"标签，但**这个数字其实是误导性简化**。
"新鲜度"实际是三个独立维度：

1. **区块新鲜度**（链端真相）：链端最新块 → 我们读到的 block，
   物理下限 = 出块时间（Ethereum 0-12s）
2. **读取新鲜度**（RPC → cache 写入）：cache 一旦写入就冻结，
   即使链上又出了 5 个块缓存值也不变。0-60s（Cache TTL）
3. **展示新鲜度**（cache → 用户屏幕）：`now - fetched_at`，0-60s

举例：用户看到 "fetched 5s ago"，但那个 block 本身已经是 12s 前出的，
此刻链端可能又走了 2 个块——**真实链端落后约 24s，标签显示却是 5s**。

把这三件事合成一个 "freshness: 35s" 在物理上不存在，是产品撒谎。

## Solution

### 核心原则：block number 是唯一客观锚点

显示方式：**block + age 并列**，不合成

```
liquidity: 1,234,567 USDC
↳ Block #19234567 · 23s ago
```

让懂的人看 block number，不懂的人看时间戳。

### 按字段属性差异化展示

| 字段类型 | 例子 | 显示策略 |
|---|---|---|
| 不可变（构造时定义） | `decimals`, `name`, `symbol` | **不显示新鲜度**（永不变，是噪声） |
| 慢速变化 | `owner`, 固定供应的 `totalSupply` | 仅显示 block，不显示时间 |
| 中速变化 | mintable `totalSupply`, 协议参数 | block + 时间 |
| 快速变化 | Uniswap `slot0` / `liquidity`, lending utilization | block + 时间 + 可选闪烁刷新 |

判断"是否可变"的依据：ABI function 的 `stateMutability`
（`pure` / `view` 不够，要看是否依赖会变的 storage —— 简单近似：
名字属于一组白名单 = 不可变；其余视作可变）。

### 实施步骤

1. **`Multicall3Client` 返回 block number**
   - batch 末尾加一个 `getBlockNumber()` call（Multicall3 自身函数，几乎免费）
   - `Result` struct 加 `block_number` 字段
2. **`ViewCaller` / `SingleCaller` 缓存值带时间戳 + block**
   - 缓存 value 从 `{fn_sig => result}` 改成
     `{block_number:, fetched_at:, values: {...}}`
3. **不可变字段白名单**
   - `IMMUTABLE_VIEW_FUNCTIONS = %w[name symbol decimals DOMAIN_SEPARATOR ...]`
   - 渲染时跳过新鲜度
4. **View 渲染**
   - `_live_state.html.erb` / `_functions.html.erb` 按字段分组渲染
   - 用 Stimulus controller `live_refresh_controller` 让时间戳每秒前进
5. **可选 P1**：Turbo Stream 在 cache 过期时把整个 frame 替换为新值，
   并加 1s `bg-yellow-100` 闪烁提示"刚刷新"

## Why this matters（产品故事）

差异化点改写：

> Smarts 是第一个 DeFi 文档**明确告诉你每个字段的状态对应哪个 block** 的。

这比"Mintlify 没有"更具体、更有可信度边界，符合 CLAUDE.md
"AI 是工具不是展示品" + "Build in Public" 的精神——**暴露真实延迟比
缩短延迟更重要**。

## 取代

这条取代 `2026-04-25-refresh-strategy-gaps-...md` 里的 "缺口 4: live
数据无新鲜度提示"——那条说的是"加个时间戳"，太粗，且是错的方向。
