---
created: 2026-04-25T13:55:08.701Z
title: Top 50 协议 proxy 升级历史实测脚本
area: general
files: []
---

## Problem

我们目前对"DeFi 主流合约多久升级一次"只有**估计值**，没有真数据。
做"是否要建 proxy upgrade 检测"这类决策时只能靠经验感拍脑袋。

而这件事一旦真做了，**直接是 Build in Public 的内容素材**——
"我们扫了 1000 个 DeFi 合约升级历史" 这种文章天然有话题性。

## Solution

等 `ChainReader` + `Multicall3Client` + 事件解码就绪后写一个脚本：

1. 维护一份 Top 50 DeFi 协议合约地址清单（所有支持的链）
2. 对每个合约：
   - 检测是否是 EIP-1967 / ZeppelinOS proxy
   - 若是 proxy → 拉所有历史 `Upgraded(address)` 事件（topic
     `0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b`）
   - Diamond → 拉 `DiamondCut` 事件
3. 输出统计：
   - 升级总次数、平均间隔、最长 / 最短间隔
   - 按协议类型分桶（AMM / Lending / Staking / Bridge / Stablecoin）
   - 与初始部署距今天数对比
4. 副产品：JSON 文件 → 喂回 Smarts 做"升级活跃度"展示
5. **写成博客**："1000 contracts, 4 chains: how often DeFi actually upgrades"

数据回来以后我们才能真正决定：
- proxy 检测是 P0 还是 P2
- lazy-on-access 够不够，还是必须订阅事件
- 哪些合约根本不用查（immutable 一族）

依赖：等 ChainReader 完整后再做（最早 Month 1 末）。
