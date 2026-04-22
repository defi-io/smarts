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
  primary: fast-mcp                   # Rack middleware 方式挂到 Rails
  fallback: RubyLLM::MCP              # 如果与 ruby_llm 集成更顺滑则切换

external_apis:
  etherscan: Etherscan V2 API (多链统一 key)
  tvl_yields: DefiLlama API (free, 做速率限制)
  prices: CoinGecko API
  rpc: Alchemy + 自建 public RPC fallback
```

### 语言边界：**纯 Ruby，无 TypeScript 微服务**

这是经过完整调研后的决策。Ruby 生态在 2026 年已经足够：
- `eth` gem（0.5.17，2026-01-26 更新）支持完整 JSON-RPC、ABI 编解码、账户和交易处理
- Multicall3 可以用 Ruby 实现（纯 ABI 编解码）
- MCP Ruby SDK（`mcp` gem）是 Anthropic 官方维护
- `fast-mcp` 让 MCP server 在 Rails 里一行 middleware 就能挂载

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
- ❌ 不做未验证合约（只接受 Etherscan 已验证）
- ❌ 不做 Solana / Bitcoin / Move 系（仅 EVM）
- ❌ 不做私有合约（即使用户提供 ABI 文件）

---

## 支持范围（MVP 硬边界）

### 支持的链（Month 1-3）
- Ethereum mainnet (chain_id: 1)
- Base (chain_id: 8453)
- Arbitrum One (chain_id: 42161)
- Optimism (chain_id: 10)
- Polygon PoS (chain_id: 137)

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
│  └─ fast-mcp (Rack middleware, mounted at /mcp)             │
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
│   │   ├── etherscan_client.rb              # Etherscan V2 API
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
│   ├── mcp/                                 # MCP tools（fast-mcp 风格）
│   │   ├── tools/
│   │   │   ├── get_contract_info.rb
│   │   │   ├── read_contract_state.rb
│   │   │   ├── simulate_transaction.rb
│   │   │   ├── get_protocol_metrics.rb
│   │   │   └── get_recent_events.rb
│   │   └── resources/
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
class Tools::ReadContractState < FastMcp::Tool
  description "Read current on-chain state of any view function"
  
  arguments do
    required(:chain).filled(:string)
    required(:address).filled(:string)
    required(:function_name).filled(:string)
    optional(:args).array
  end
  
  def call(chain:, address:, function_name:, args: [])
    # 直接调用 Service Object，不持有业务逻辑
    result = ChainReader::ViewCaller.call(
      chain: Chain.find_by!(slug: chain),
      address: address,
      function_name: function_name,
      args: args
    )
    { value: result.value, block: result.block_number }
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
  - `mcp.smarts.md` → 同一 Rails 进程的 `/mcp` 路径（fast-mcp middleware）
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
- Week 7-8: fast-mcp 挂载 + MCP tools 实现 + Claude Code 端到端测试

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
- fast-mcp: https://github.com/yjacquin/fast-mcp
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

_Last updated: 2026-04-20_  
_Maintained by: Bob (汪晓明) with Claude_
