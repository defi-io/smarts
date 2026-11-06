# CLAUDE.md — Smarts (smarts.md)

> 这份文档是项目的"第一源"。每个 Claude Code session 开始时会被自动加载。
> 修改技术决策时，先改这里，代码再跟进。

---

## 项目身份

**产品代号**：Smarts  
**主域名**：smarts.md  
**定位**：为智能合约生成 live docs 和 MCP server 的 AI 原生文档平台  
**Tagline**：Live docs for every smart contract.  
**创始人**：汪晓明（Bob，HPB 创始人，一人公司模式）

### 域名矩阵

| 域名 | 角色 | 当前状态 |
|---|---|---|
| **smarts.md** | 产品主入口 / 主品牌 ★ | 本项目主战场 |
| smartcontract.md | SEO 关键词站 | 301 重定向到 smarts.md |
| chains.md | 平台延展占位 | 挂 "Part of Smarts ecosystem" |
| chain.dev | 母品牌 / 公司 | 简单"关于"页 |
| defi.io | 用户侧应用（中期）| Coming soon |
| defi.fund | 金融产品（长期）| Coming soon |
| defi.club | 社群（合伙人并行跑）| 合伙人主导，本项目不涉及 |

> **GitHub org**：本项目仓库托管在 `github.com/defi-io/smarts`（2026-04 从 `defifund` 迁移过来，与 defi.io 品牌对齐）。

---

## 产品核心

### 一句话定义
输入一个已验证的合约地址（比如 `smarts.md/eth/0x1f98...`），30 秒生成一个**实时同步链上状态**的文档站，同时自带可被 Claude Code / Cursor 等 AI agent 直接调用的 MCP 端点。

### 与 Mintlify 的结构性差异

| 维度 | Mintlify | Smarts |
|---|---|---|
| 核心数据源 | Git 仓库 + 手写 Markdown | 合约 ABI + 链上 RPC + 源码 |
| 内容更新 | Agent 写 PR | 链上状态实时读取 |
| 文档颗粒度 | 项目级（repo → site）| 合约级（address → site）|
| MCP server 内容 | 静态文档文本 | 文档 + 实时链上查询 |
| 交互能力 | 代码示例（只读）| 函数可直接 live call |
| 目标客户 | 所有需要文档的公司 | DeFi/Web3 协议 + 开发者 + AI agent |

### MVP 路线（路线 B：窄深）
**只做 DeFi Top 50 协议的合约级专家文档**，不做通用合约文档生成器。

理由：广度打不过 Mintlify 的工程速度，但深度上我们有链上原生 + Web3 老兵的双重优势。Top 50 协议覆盖 90%+ 市场心智。

---

## 技术栈（硬性约束）

### 核心选型

```yaml
language: Ruby 3.3+
framework: Rails 8.x
database: PostgreSQL 17
cache: Solid Cache
queue: Solid Queue
cable: Solid Cable
frontend: Hotwire (Turbo + Stimulus) + ERB
css: Tailwind CSS
deploy: Kamal 2 + Thruster
target: Hetzner VPS (CPX31 起步)

onchain:
  primary_gem: eth (q9f/eth.rb, ~> 0.5.17)
  multicall3: 0xcA11bde05977b3631167028862bE2a173976CA11  # 所有主流 EVM 链统一

ai:
  gem: ruby_llm
  fast: gpt-5-mini                   # 分类、快速描述（MVP 默认，成本优先）
  main: gpt-5                        # 主力文档生成
  heavy: claude-opus-4-7             # 复杂协议分析（少用，质量优先）
  # 说明：initializer 同时配置 OpenAI + Anthropic。模型名字符串改一下就切。
  #       产品成熟、Anthropic API credits 到位后可回切 Claude 以保持品牌统一。

mcp:
  primary: mcp                        # Anthropic 官方 Ruby SDK，支持 Streamable HTTP
                                      # （MCP spec 2025-03-26）。Rails 里 `mount transport => "/mcp"`。
                                      # 用 stateless: true 模式，Puma 多进程友好。
  legacy: fast-mcp                    # 已弃用——只支持老版 HTTP+SSE，被 Smithery / Cursor 等
                                      # 现代客户端拒绝。2026-04 完成迁移，不再使用。

external_apis:
  etherscan: Etherscan V2 API (多链统一 key)
  blockscout: 链自有 Blockscout 实例的 Etherscan 兼容 /api
              （当前用于 Robinhood Chain，见下方"区块浏览器数据源"）
  sourcify: Sourcify 验证 API（当前用于 Arc；ArcScan 已上线，但源码索引尚不完整）
  tvl_yields: DefiLlama API (free, 做速率限制)
  prices: CoinGecko API
  polymarket: Gamma + CLOB read-only APIs (Polymarket 例外，见下文)
  rpc: Alchemy + 自建 public RPC fallback
```

### 语言边界：**纯 Ruby，无 TypeScript 微服务**

这是经过完整调研后的决策。Ruby 生态在 2026 年已经足够：
- `eth` gem（0.5.17，2026-01-26 更新）支持完整 JSON-RPC、ABI 编解码、账户和交易处理
- Multicall3 可以用 Ruby 实现（纯 ABI 编解码）
- MCP Ruby SDK（`mcp` gem）是 Anthropic 官方维护
- `mcp` 官方 SDK 让 MCP server 在 Rails 里一行 `mount` 就能挂载，且支持 Streamable HTTP 传输

**只有以下四个情况触发时才引入 TS**（目前都不存在）：
1. 前端钱包交互 UI（本 MVP 不做）
2. Frame/Farcaster/Lens 等 TS-only 生态
3. Ruby 性能真的瓶颈（读 view 函数不会）
4. 出现必须用的 TS-only 工具且无 Ruby 替代

### 禁忌（绝对不做）

- ❌ 不引入 TypeScript / Node.js 服务
- ❌ 不引入 ethers.js / web3.js
- ❌ 不引入 Sidekiq（用 Solid Queue）
- ❌ 不引入 React / Vue / Svelte（用 Hotwire）
- ❌ 不引入 Redis（用 Solid Cache / Solid Queue / Solid Cable 全覆盖）
- ❌ 不引入 SPA 构建工具（esbuild/webpack 默认即可）
- ❌ 不做未验证合约（只接受对应数据源已验证：Etherscan V2 / Blockscout / Sourcify）
- ❌ 不做 Solana / Bitcoin / Move 系（仅 EVM）
- ❌ 不做私有合约（即使用户提供 ABI 文件）

---

## 支持范围（MVP 硬边界）

### 支持的链 — 两层 tier 制度

链注册的唯一数据源是 `db/seeds/chains.rb`，由 `Chains::Seeder.call`（幂等）应用。
**不再写 per-chain data migration**（`db/migrate/*_add_<chain>_chain.rb` 已废弃，参见 `add_bnb_chain.rb` 头部注释）。
Production 部署由 `bin/docker-entrypoint` 在 server 启动时自动跑 `Chains::Seeder.call`。

**Tier 1 — `full`**：完整能力，live state + activity + governance + admin/risk + protocol adapters。
- Ethereum (1) / Base (8453) / Arbitrum One (42161) / Optimism (10) / Polygon PoS (137) / BNB Smart Chain (56) / Robinhood Chain (4663) / Arc (5042)
- 配置必备：`rpc_url`，所有链上读取走 `ChainReader::*`（Multicall3 + view caller + event decoder）
- 适用于：Top DeFi 协议、需要 AI agent 查实时状态的合约

**区块浏览器数据源**：源码 / ABI 默认走 Etherscan V2（`api.etherscan.io/v2/chainlist` 当前 63 条链）。
Robinhood Chain 4663 虽已列入 Etherscan V2，但其新索引仍把已验证的 WETH implementation 标为
未验证；目前继续走该链 Blockscout 实例的 Etherscan 兼容 `/api`。
分发在 `Chain#explorer_client`（按 `explorer_api_url` 判断），三个 client 都继承 `ExplorerClient`，
共用 `ExplorerClient::Error` / `NotVerifiedError`，所以加数据源不动任何调用点。
Blockscout 的三处差异（未验证无 sentinel、代理字段是 `IsProxy`/`ImplementationAddress`、ABI 内联在
`getsourcecode`）都收在 `BlockscoutClient` 里。公共 Blockscout 实例限流很硬且无 key —— 只在
"首次索引某合约"时打一次，之后落库，不要写批量抓取。

**Arc（5042）的数据源 —— 与其他链都不同（2026-09-16 实测）**：
- `arc.etherscan.io`（ArcScan）已经上线，Etherscan V2 chainlist 也已收录 Arc。用户侧的地址、
  交易和验证链接都走 ArcScan；源码/ABI 暂时仍走 **Sourcify**。
- Sourcify 不是 Etherscan 形状：按路径寻址 `v2/contract/<chainId>/<address>`，没有
  `status`/`message` 信封，未验证时返回 HTTP 404 且 `match` 为 null。差异全部收在
  `SourcifyClient` 里，基类只多了一个 `request_path` 扩展点。
- Sourcify 自带 proxy 解析（`proxyResolution.implementations[]`），且 `sources` 直接就是
  `{path => {content}}`，不需要像 Blockscout 那样重组 `AdditionalSources`。
- ⚠️ ArcScan 上线当天的源码索引仍很稀疏：项目收录的六个合约中，USDC 只有 proxy 已验证，
  implementation 未验证，其余五个也无法由 Etherscan API 完整读取，因此切换会造成回归。
  Sourcify 当前至少可完整读取 Permit2。继续定期探测这六个地址，覆盖率不低于 Sourcify 后
  再把 `explorer_api_url` 切到 Etherscan V2。RPC 侧工具不受此选择影响。
- gas token 是**原生 USDC**（`0x3600…0000` predeploy），不是 ETH；`NATIVE_SYMBOLS` 已特判。
  注意其内部 18 decimals 而 ERC-20 表面 6 decimals，transfer 由 system emitter 发出。
- 公共 RPC `rpc.mainnet.arc.io`（另有 QuickNode / Blockdaemon / dRPC 镜像）实测
  `eth_call` / `eth_getCode` / `eth_getLogs` 均可用，无需 key。`eth_getLogs` 单次上限
  **2000 条**，报错文案 `query exceeds max results 2000` 已被 `RecentFetcher` 的
  `shrinkable_rpc_error?` 覆盖，自适应收窗无需改动。生产可用 `ARC_RPC_URL` 覆盖。

**Robinhood Chain 的公共端点限流（2026-09 实测）**：Blockscout 和公共 RPC 都是"长惩罚期"限流——
一次几十个请求的爆发会让**整个出口 IP** 被锁 30 分钟以上，不是滑动窗口。RPC 的 `eth_call` /
Multicall3 很便宜（Live State 稳定可用），但 `eth_getLogs` 有独立的重方法预算，几次就打光，
Activity / Governance 会返回 429。Robinhood 官方文档也明说公共 RPC "not recommended for
production"。所以：这条链正式对外推之前，先拿 Blockscout API key（dev.blockscout.com），并通过
`ROBINHOOD_RPC_URL` 配置 Alchemy endpoint；不要把 provider key 写进 seed 或数据库。未配置时继续
使用 seed 里的公共 RPC，仅适合本地开发和低流量读取。

**Tier 2 — `docs_only`**：只索引源代码 + ABI，不调 RPC。
- 当前：Linea (59144)
- 数据源：Etherscan V2 `getsourcecode` / `getabi` —— Etherscan **官方对所有支持链 + Free tier 都开放这两个端点**（其他端点如 `getLogs` 只在 paid + selected chains）
- 配置：`rpc_url: nil`
- 启用的 MCP tools：`get_contract_info`、`get_contract_source`
- 禁用的 MCP tools（友好返回 docs-only error，不会 timeout）：`read_contract_state`、`get_erc20_info`、`get_uniswap_v3_pool`、`get_recent_events`、`get_governance_timeline`、`get_admin_risk`、`inspect_address`
- UI：show 页面只渲染 Docs + Source tabs，隐藏 Live State / Activity / Governance tabs，顶部显示 docs-only notice
- 价值：用零额外成本覆盖长尾 EVM 链，引流长尾开发者，反向推广主流链

加新链流程：编辑 `db/seeds/chains.rb` → `bin/rails db:seed`（或部署即自动跑）。

### 支持的合约
- 必须是 Solidity 编写
- 必须在对应 Etherscan 上已验证
- 包括 proxy 合约（EIP-1967 / 透明代理 / UUPS），需要解析到 implementation

### 支持的协议（Month 1-3 优先级）

| 月份 | 协议 | 适配器 |
|---|---|---|
| Month 1 | Uniswap V3 Pool | UniswapV3Adapter |
| Month 2 | Uniswap V3 全生态（Router、Factory、NFTManager）| UniswapV3Adapter 扩展 |
| Month 3 | Aave V3 | AaveV3Adapter |
| Month 3 | 通用 ERC-20 / ERC-721 | GenericErc20Adapter |
| Month 4+ | Polymarket (CTFExchange / NegRiskCtfExchange / ConditionalTokens / UmaCtfAdapter) | PolymarketAdapter |

### Polymarket（off-chain API 例外）

Polymarket 是唯一允许调用 off-chain REST API 的协议适配器。理由：
- Polymarket 是 off-chain order book + on-chain settlement 模型，当前市场元数据、赔率和订单簿不完整存在链上；必须读取 `gamma-api.polymarket.com` 和 `clob.polymarket.com`
- “AI agent 查询事件市场状态/赔率”是 Smarts 的高价值 MCP 场景；只看链上 settlement 无法回答核心问题
- 仅限只读请求；下单、签名、交易、钱包连接仍然绝对不做

实现位置：
- `app/services/polymarket_client.rb`：Faraday + Solid Cache，负责 Gamma/CLOB HTTP 边界
- `app/services/polymarket/*`：market、position、resolution 编排
- `app/services/chain_reader/conditional_tokens_reader.rb`：Gnosis CTF on-chain state/balance reads
- `app/tools/get_polymarket_market_tool.rb` / `get_polymarket_position_tool.rb`：MCP 入口

支持的合约固定为 Polygon mainnet，见 `app/services/contract_slugs.rb` 的 `polymarket-*` curated slugs。

---

## 架构

### 单 Rails 进程架构

```
┌──────────────────────────────────────────────────────────────┐
│                    smarts.md (Rails 8)                       │
│                                                              │
│  Presentation Layer                                         │
│  └─ Controllers + ERB + Hotwire + Tailwind                  │
│                                                              │
│  Business Layer (Service Objects under app/services/)       │
│  ├─ ContractDocument::Fetcher        (主编排)                │
│  ├─ ContractDocument::Classifier     (协议识别)              │
│  ├─ ContractDocument::AiEnricher     (ruby_llm → Claude)    │
│  └─ ProtocolAdapters::*              (协议适配器)            │
│                                                              │
│  External Integration Layer                                 │
│  ├─ EtherscanClient    (HTTP via Faraday)                   │
│  ├─ DefiLlamaClient    (HTTP)                               │
│  ├─ CoinGeckoClient    (HTTP)                               │
│  └─ ChainReader        (eth gem 封装)                        │
│      ├─ Multicall3Client                                    │
│      ├─ ViewCaller                                          │
│      ├─ EventDecoder                                        │
│      └─ ProxyResolver                                       │
│                                                              │
│  MCP Layer                                                   │
│  └─ mcp gem (StreamableHTTPTransport, mounted at /mcp)      │
│      └─ Tools → 直接调用 Service Objects                     │
│                                                              │
│  Infrastructure                                              │
│  ├─ PostgreSQL 17                                           │
│  └─ Solid Cache / Solid Queue / Solid Cable                │
└──────────────────────────────────────────────────────────────┘
                             │
                             ▼
                  Hetzner VPS (Kamal 2 部署)
```

### 核心数据流

```
用户请求: smarts.md/eth/0x1f98...
    │
    ▼
[ContractsController#show]
    │
    ▼
[ContractDocument::Fetcher.call(chain:, address:)]
    │
    ├── 1. 查 DB: Contract.find_by(chain:, address:)
    │       ├─ 新鲜（<1h）→ 直接渲染（Solid Cache 命中）
    │       └─ 过期或不存在 → 继续
    │
    ├── 2. 并发获取
    │       ├─ EtherscanClient → ABI + 源码 + NatSpec
    │       └─ ChainReader::Multicall3 → 所有 view 函数当前值
    │
    ├── 3. 识别协议
    │       ├─ bytecode hash 匹配 → 已知协议模板
    │       └─ 未知 → ERC 识别 fallback
    │
    ├── 4. AI 富化 (Haiku 分类 → Sonnet 生成)
    │
    ├── 5. 外部数据（按协议类型）
    │       ├─ DEX → DefiLlama TVL + CoinGecko 价格
    │       └─ Lending → DefiLlama rates
    │
    ├── 6. 持久化 + 缓存
    │       ├─ Contract.update(...)
    │       └─ Solid Cache (60s revalidate)
    │
    └── 7. 渲染 ERB + Turbo Frame 局部刷新 live 数据
```

---

## 目录结构

```
smarts/
├── app/
│   ├── controllers/
│   │   ├── contracts_controller.rb          # GET /:chain/:address
│   │   ├── mcp_controller.rb                # 给 MCP tools 用的内部 API
│   │   └── marketing_controller.rb          # landing page
│   │
│   ├── models/
│   │   ├── chain.rb                         # 支持的链
│   │   ├── contract.rb                      # 合约主模型
│   │   ├── protocol.rb                      # 已识别的协议
│   │   ├── abi_function.rb                  # 解析后的函数
│   │   └── contract_snapshot.rb             # 链上状态快照（时序）
│   │
│   ├── services/
│   │   ├── contract_document/
│   │   │   ├── fetcher.rb                   # 主编排 service
│   │   │   ├── classifier.rb                # 协议识别
│   │   │   └── ai_enricher.rb               # ruby_llm 调 Claude
│   │   │
│   │   ├── chain_reader/                    # 链上交互封装（纯 Ruby）
│   │   │   ├── base.rb                      # 共享的 eth client 初始化
│   │   │   ├── multicall3_client.rb         # 批量 eth_call
│   │   │   ├── view_caller.rb               # 单函数 eth_call
│   │   │   ├── event_decoder.rb             # 事件日志解码
│   │   │   └── proxy_resolver.rb            # EIP-1967 / 透明代理识别
│   │   │
│   │   ├── explorer_client.rb               # 浏览器 client 基类（错误类型 / 限流 / Faraday）
│   │   ├── etherscan_client.rb              # Etherscan V2 API
│   │   ├── blockscout_client.rb             # Blockscout 兼容 API（当前用于 Robinhood Chain）
│   │   ├── sourcify_client.rb               # Sourcify 验证 API（当前用于 Arc）
│   │   ├── defillama_client.rb              # DefiLlama
│   │   ├── coingecko_client.rb              # CoinGecko
│   │   │
│   │   └── protocol_adapters/
│   │       ├── base_adapter.rb              # 适配器基类
│   │       ├── uniswap_v3_adapter.rb        # Month 1-2
│   │       ├── aave_v3_adapter.rb           # Month 3+
│   │       └── generic_erc20_adapter.rb     # fallback
│   │
│   ├── jobs/
│   │   ├── refresh_contract_job.rb          # 定时刷新热合约
│   │   ├── classify_contract_job.rb         # 异步协议分类
│   │   └── warmup_cache_job.rb              # 预热 Top 50 缓存
│   │
│   ├── tools/                               # MCP tools（mcp gem 风格）
│   │   ├── application_tool.rb              # 基类（slug/chain+address 解析、Hash → MCP::Tool::Response）
│   │   ├── get_contract_info_tool.rb        # 合约元数据
│   │   ├── get_contract_source_tool.rb      # 源码索引/取文件/grep
│   │   ├── get_erc20_info_tool.rb           # ERC-20 实时元数据
│   │   ├── get_recent_events_tool.rb        # 合约近期事件（按 ABI 解码）
│   │   ├── get_uniswap_v3_pool_tool.rb      # Uniswap V3 池实时状态
│   │   ├── inspect_address_tool.rb          # 任意地址分类（EOA / contract / EIP-7702）
│   │   └── read_contract_state_tool.rb      # 通用 view 函数读取
│   │
│   ├── views/
│   │   ├── contracts/
│   │   │   ├── show.html.erb                # 主文档页
│   │   │   ├── _overview.html.erb           # Turbo Frame: 协议概览
│   │   │   ├── _live_state.html.erb         # Turbo Frame: 实时数据
│   │   │   ├── _functions.html.erb          # Turbo Frame: 函数列表
│   │   │   └── _mcp_info.html.erb           # MCP endpoint 信息卡片
│   │   └── layouts/
│   │
│   └── javascript/
│       └── controllers/                     # Stimulus 控制器
│           ├── copy_mcp_url_controller.js
│           └── live_refresh_controller.js
│
├── config/
│   ├── routes.rb
│   ├── kamal/
│   │   └── deploy.yml                       # Kamal 2 配置
│   └── initializers/
│       ├── ruby_llm.rb                      # Claude 配置
│       ├── fast_mcp.rb                      # MCP server 挂载点
│       └── chain_reader.rb                  # eth gem 配置
│
├── test/                                    # minitest
│
├── CLAUDE.md                                # 本文件（项目第一源）
├── Gemfile
└── Dockerfile
```

---

## Ruby 编码约定

### 通用

- 严格遵守 Rails 约定优于配置，不创造额外抽象
- 文件/目录命名用 snake_case，类名用 CamelCase
- 一个文件一个主类，辅助类写在同一文件里只有紧密关联时
- `app/services/*` 下所有 service 实现 `call` 类方法（`SomeService.call(...)` 模式）
- 所有 service 返回 `Result` 对象或抛明确异常，不返回原始 hash

### 链上交互专项

```ruby
# 正确 ✅
class ChainReader::Multicall3Client
  MULTICALL3_ADDRESS = "0xcA11bde05977b3631167028862bE2a173976CA11"
  
  def initialize(chain)
    @chain = chain
    @client = Eth::Client.create(chain.rpc_url)
  end
  
  def aggregate3(calls)
    # 封装 Multicall3 合约的 aggregate3 调用
  end
end

# 错误 ❌ 直接在 Controller 或 Model 里调 eth gem
class ContractsController < ApplicationController
  def show
    client = Eth::Client.create(...)  # 禁止
  end
end
```

**所有链上交互必须经过 `app/services/chain_reader/*`**。Controller 和 Model 永远不直接调 eth gem。

### 外部 API 调用

- 使用 Faraday + Faraday::Retry
- 每个外部 API 有独立的 Client 类（`EtherscanClient`、`DefiLlamaClient` 等）
- 所有外部调用必须有 Solid Cache 缓存层
- 所有外部调用必须有超时（默认 10s）和错误处理
- 不得在 Controller 或 View 里直接发 HTTP 请求

### AI 调用（ruby_llm）

```ruby
# 按任务复杂度选模型
# 分类、短描述 → Haiku
# 主力文档生成 → Sonnet
# 复杂协议分析（谨慎）→ Opus

class ContractDocument::AiEnricher
  def classify_functions(abi_functions)
    chat = RubyLLM.chat(model: "claude-haiku-4-5-20251001")
    # ...
  end
  
  def generate_function_docs(function, context)
    chat = RubyLLM.chat(model: "claude-sonnet-4-6")
    # ...
  end
end
```

**AI 调用必须缓存**：同一 ABI 哈希 + 同一提示词 = 同一结果，用 Solid Cache 长期缓存（7 天）。

### MCP tools

```ruby
# app/mcp/tools/read_contract_state.rb
class ReadContractStateTool < ApplicationTool
  tool_name "read_contract_state"
  description "Read current on-chain state of any view function"

  input_schema(
    properties: {
      chain:         { type: "string" },
      address:       { type: "string" },
      function_name: { type: "string" },
      args:          { type: "array" }
    },
    required: [ "chain", "address", "function_name" ]
  )

  class << self
    # 业务逻辑只返回 Hash；ApplicationTool 的 self.call 会包成
    # MCP::Tool::Response。tests 直接 .payload(...) 断言。
    def payload(chain:, address:, function_name:, args: [])
      result = ChainReader::ViewCaller.call(
        chain: Chain.find_by!(slug: chain),
        address: address,
        function_name: function_name,
        args: args
      )
      { value: result.value, block: result.block_number }
    end
  end
end
```

MCP tools 只是**协议翻译层**，真正的业务逻辑在 Service Objects 里。

### 前端

- **所有新功能默认 Server Component** — 只用 Turbo Frames 和 Stimulus 做局部交互
- 不写任何自定义 JS 框架，所有 JS 都是 Stimulus controller
- Live 链上数据用 Turbo Streams 推送（通过 `turbo_stream.update`）或定时 Turbo Frame 刷新
- 样式只用 Tailwind 原生类，必要时加 `@apply` 组件到 `application.tailwind.css`

---

## 缓存策略

| 数据类型 | 缓存层 | TTL |
|---|---|---|
| Etherscan ABI 响应 | Solid Cache | 30 天（ABI 不变）|
| 合约源码 | Solid Cache | 30 天 |
| view 函数当前值 | Solid Cache | 60 秒 |
| DefiLlama TVL/APY | Solid Cache | 5 分钟 |
| CoinGecko 价格 | Solid Cache | 1 分钟 |
| AI 生成的函数描述 | Solid Cache | 7 天（按 abi_hash + prompt_version）|
| 整个渲染页面 | Rails fragment cache | 60 秒 |

**缓存 key 规则**：`<scope>:<chain>:<address>:<method>`，例如 `etherscan:eth:0x1f98...:get_source_code`。

---

## 测试

- 框架：minitest（Rails 8 默认）+ fixtures
- **必须单测的部分**：
  - `app/services/chain_reader/*`（所有链上交互封装）
  - `app/services/protocol_adapters/*`（协议适配器）
  - `app/services/contract_document/*`（主编排和 AI 富化）
- **至少一个端到端测试**：拉取 Uniswap V3 USDC/WETH 0.05% 池的真实文档（用 VCR 录制 HTTP 响应）
- CI 在 GitHub Actions 里跑，合并前必须绿

---

## 部署（Kamal 2）

- 目标：Hetzner VPS（CPX31，4 vCPU 8GB，$13/月起步）
- 单机跑：Rails + PostgreSQL（Kamal accessories）
- 域名：
  - `smarts.md` → Rails 主站
  - `mcp.smarts.md` → 同一 Rails 进程的 `/mcp` 路径（mcp gem 的 StreamableHTTPTransport）
  - `smartcontract.md` → 301 到 `smarts.md`
- SSL：Kamal 2 proxy 自动 Let's Encrypt
- 环境变量管理：Kamal secrets + `.kamal/secrets`

---

## Git 工作流

- **主分支**：`main`（受保护，不直接 push）
- **开发**：所有改动走 feature branch → PR → 合并
- **Claude Code 默认行为**：在 feature branch 上工作，commit 遵循规范，PR 描述包含变更意图
- **Commit 前缀**：
  - `feat:` 新功能
  - `fix:` bug 修复
  - `chore:` 杂务（依赖升级、配置）
  - `docs:` 文档
  - `refactor:` 重构（无行为变化）
  - `perf:` 性能
  - `test:` 测试
- **示例**：`feat(chain_reader): implement Multicall3 aggregate3 wrapper`

---

## Claude Code 使用约定

### 当我说"开始做 X"时

1. 先检查 `CLAUDE.md` 的约束是否允许这个做法
2. 再检查现有代码中是否有相关实现（不要重复造轮子）
3. 写代码前先开一个新 branch（除非明确说在现有 branch 上工作）
4. 实现完成后跑测试，确保绿了再交付
5. **不要自动 git commit**——改动写完、测试跑绿后停下来汇报，等我明确说 "commit" 再提交。提交时用规范 commit 前缀。

### 当我说"我有个想法"时

不要立刻写代码。先：
1. 确认理解正确（复述一遍）
2. 评估是否符合 CLAUDE.md 约束
3. 指出潜在问题或更好的替代方案
4. 等我确认再动手

### 当遇到技术选择分叉时

在 CLAUDE.md 没有明确规定时：
1. 默认选"更 Rails 原生"的方案
2. 默认选"更少依赖"的方案
3. 默认选"能让一人开发者更快迭代"的方案
4. 不确定时停下来问我

### 禁止行为

- ❌ 不要未经确认引入新 gem
- ❌ 不要未经确认修改 Gemfile / package.json
- ❌ 不要未经确认改架构（新增微服务、换数据库等）
- ❌ 不要"顺手"清理无关代码
- ❌ 不要写"将来可能用到"的代码（YAGNI）

---

## 90 天里程碑

### Month 1：单合约全链路打通
- Week 1: Rails 8 骨架 + Kamal 部署 + 核心 model
- Week 2: EtherscanClient + 最小 controller/view
- Week 3: ChainReader::Multicall3Client + live view 函数展示
- Week 4: UniswapV3Adapter + DefiLlama 集成，单池文档 polished

### Month 2：协议识别 + MCP server
- Week 5-6: bytecode hash 分类 + ruby_llm 集成
- Week 7-8: `mcp` gem 挂载 + MCP tools 实现 + Claude Code 端到端测试

### Month 3：扩展 + 发布准备
- Week 9-10: 所有 Uniswap V3 池支持 + AaveV3Adapter 草稿
- Week 11-12: 性能优化 + SEO + Launch 文章 + Product Hunt 准备

### 90 天结束硬性验收
- [ ] smarts.md 可访问
- [ ] 至少覆盖 Uniswap V3 所有池
- [ ] 每个文档页自带可工作的 MCP server endpoint
- [ ] 从 Claude Code 里能连到 smarts.md 的 MCP 查询任意池的实时状态
- [ ] 至少 1 个 KOL 在 X 或 WeChat 公开推荐

---

## 参考链接（重要外部文档）

- eth gem: https://github.com/q9f/eth.rb
- ruby_llm: https://rubyllm.com
- mcp (Anthropic 官方 Ruby SDK): https://github.com/modelcontextprotocol/ruby-sdk
- MCP 官方 Ruby SDK: https://github.com/modelcontextprotocol/ruby-sdk
- Multicall3: https://www.multicall3.com
- Etherscan V2 API: https://docs.etherscan.io/etherscan-v2
- DefiLlama API: https://defillama.com/docs/api
- Uniswap V3 合约：https://docs.uniswap.org/contracts/v3/reference/deployments
- Aave V3 合约：https://aave.com/docs/resources/addresses
- Rails 8 发布说明：https://guides.rubyonrails.org/8_0_release_notes.html
- Kamal 2：https://kamal-deploy.org

---

## 核心原则（贴在墙上）

1. **纯 Rails 8，一个进程，一种语言，一套部署**
2. **合约是一等公民，文档是它的投影**
3. **AI 是工具，不是展示品**——用得恰到好处而非处处炫耀
4. **不做 Solana，不做钱包连接，不做未验证合约**——MVP 边界神圣不可侵犯
5. **速度 > 完美**——先让它活，再让它好
6. **Build in Public**——代码、思考、挫折都公开

---

_Last updated: 2026-09-16_
_Maintained by: Bob (汪晓明) with Claude_
