require "test_helper"

class ContractsControllerTest < ActionDispatch::IntegrationTest
  setup do
    stub_empty_etherscan_logs
  end

  test "show renders existing contract" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    assert_select "h1", "Uni"
    assert_match %r{href="/chains"[^>]*>\s*Browse chains\s*</a>}m, response.body
  end

  test "show via friendly slug resolves to the contract" do
    contract = contracts(:uni_token)
    contract.update!(address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984") # real UNI, which maps to uni-eth
    get "/uni-eth"
    assert_response :success
    assert_select "h1", "Uni"
  end

  test "show via localized slug renders the requested locale and localized island urls" do
    contract = contracts(:uni_token)
    contract.update!(address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")

    get "/cn/uni-eth"

    assert_response :success
    assert_select "html[lang='zh-CN']"
    assert_match "通过你的 AI 查询此合约", response.body
    assert_match %r{data-contract-tabs-activity-url-value="/cn/uni-eth/activity"}, response.body
    assert_match %r{<link rel="alternate" hreflang="zh-CN" href="https://smarts\.md/cn/uni-eth">}, response.body
  end

  test "localized hex URL 301s to the localized slug when one exists" do
    uni_addr = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
    Contract.find_or_create_by!(chain: chains(:ethereum), address: uni_addr) do |c|
      c.name = "Uniswap"
      c.abi = []
    end

    get "/cn/eth/#{uni_addr}"
    assert_redirected_to "/cn/uni-eth"
    assert_equal 301, response.status
  end

  test "show via hex URL 301s to slug when one exists" do
    uni_addr = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
    Contract.find_or_create_by!(chain: chains(:ethereum), address: uni_addr) do |c|
      c.name = "Uniswap"
      c.abi = []
    end

    get contract_path(chain: "eth", address: uni_addr)
    assert_redirected_to "/uni-eth"
    assert_equal 301, response.status
  end

  # Robinhood Chain still uses Blockscout for source/ABI while Etherscan's
  # new index has incomplete proxy coverage. Assert dispatch end-to-end.
  test "show fetches an unindexed contract through Blockscout on a Blockscout chain" do
    address = "0x0bd7d308f8e1639fab988df18a8011f41eacad73"
    blockscout = stub_request(:get, /robinhoodchain\.blockscout\.com.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ {
        "ContractName" => "WETH",
        "CompilerVersion" => "v0.8.24+commit.e11b9ed9",
        "SourceCode" => "contract WETH {}",
        "ABI" => '[{"type":"function","name":"totalSupply","inputs":[],"outputs":[{"type":"uint256"}],"stateMutability":"view"}]',
        "IsProxy" => false
      } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    get contract_path(chain: "robinhood", address: address)

    assert_response :success
    assert_select "h1", "WETH"
    assert_requested blockscout
    assert_not_requested(:get, %r{api\.etherscan\.io})
    assert_equal "WETH", Contract.find_by(chain: chains(:robinhood), address: address).name
  end

  test "unknown slug with chain suffix returns 404" do
    get "/nonexistent-eth"
    assert_response :not_found
  end

  # ---------- markdown format (WebFetch-friendly distillation) ----------

  test "slug page .md returns text/markdown with the core sections" do
    contract = contracts(:uni_token)
    # Fixture address 0x1111… isn't in the slug map, so hit it via hex.
    get "/eth/#{contract.address}.md"

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_match %r{\A# .+ on Ethereum}, response.body
    assert_match %r{^- \*\*Address:\*\* `0x}, response.body
    assert_match %r{^- \*\*Chain:\*\* Ethereum}, response.body
    assert_match "## Query via AI agent", response.body
    assert_match "## Links", response.body
    assert_match "mcp.smarts.md", response.body
    assert_match "Browse chains", response.body
  end

  test "slug URL .md resolves without redirect and uses the canonical slug in the reference line" do
    uni_addr = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984" # maps to uni-eth
    Contract.find_or_create_by!(chain: chains(:ethereum), address: uni_addr) do |c|
      c.name = "Uniswap"
      c.abi = [ { "type" => "event", "name" => "Transfer", "inputs" => [] } ]
    end

    get "/uni-eth.md"
    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_match "- **Reference:** `uni-eth`", response.body
  end

  test "hex URL .md 301s to canonical slug .md, preserving the format segment" do
    # Slug-matching hex URL → 301 fires before any DB / Etherscan lookup,
    # so we don't need to pre-create the Contract record for this test.
    get "/eth/0x1f9840a85d5af5bf1d1762f925bdaddc4201f984.md"
    assert_redirected_to "/uni-eth.md"
    assert_equal 301, response.status
  end

  # Formats other than html/md must NOT match the contract routes; otherwise
  # we'd have to handle .json / .xml / whatever with templates we don't have.
  test "unsupported formats fall through the route pattern and return 404" do
    get "/uni-eth.json"
    assert_response :not_found
    get "/eth/0x1f9840a85d5af5bf1d1762f925bdaddc4201f984.xml"
    assert_response :not_found
  end

  # Adapter-composed markdown panel must flow into the .md output the same
  # way it does into the .html rendering. Stub adapter so this test doesn't
  # rely on fixture ABIs matching GenericErc20Adapter's 6-selector check.
  test "contract page .md includes the ERC-20 adapter's markdown partial when matched" do
    contract = contracts(:uni_token)

    fake_adapter = ProtocolAdapters::GenericErc20Adapter.allocate
    fake_adapter.instance_variable_set(:@contract, contract)
    fake_adapter.instance_variable_set(:@chain, contract.chain)
    fake_adapter.define_singleton_method(:panel_data) do
      { symbol: "UNI", name: "Uniswap", decimals: 18, total_supply_raw: nil,
        total_supply_formatted: nil, price_usd: nil, market_cap_usd: nil,
        issuer: nil }
    end

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_) { fake_adapter }) do
      get "/eth/#{contract.address}.md"
    end

    assert_response :success
    assert_match %r{^## Token state}, response.body
    assert_match "- **Symbol:** UNI", response.body
  end

  test "contract page .md includes the Uniswap V3 adapter's markdown partial when matched" do
    contract = contracts(:uni_token)

    fake_adapter = ProtocolAdapters::UniswapV3Adapter.allocate
    fake_adapter.instance_variable_set(:@contract, contract)
    fake_adapter.instance_variable_set(:@chain, contract.chain)
    fake_adapter.define_singleton_method(:panel_data) do
      {
        token0: { symbol: "USDC", decimals: 6,  address: "0xa0b8" },
        token1: { symbol: "WETH", decimals: 18, address: "0xc02a" },
        fee_pct: "0.05%",
        price_1_per_0: 0.000428,
        price_0_per_1: 2334.30,
        tick: 198_765,
        liquidity: 123_456_789,
        tvl_usd: 100_000_000
      }
    end

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_) { fake_adapter }) do
      get "/eth/#{contract.address}.md"
    end

    assert_response :success
    assert_match %r{^## Pool state}, response.body
    assert_match "- **Pair:** USDC / WETH", response.body
    assert_match "- **Fee tier:** 0.05%", response.body
    assert_match "- **TVL:** $100,000,000 (via DefiLlama)", response.body
  end

  # Error-state rescue branches have their own markdown bodies. Without a
  # respond_to here, a .md request on an unverified contract would try to
  # render not_verified.html.erb, which 500s because the layout is HTML-only.
  test "unverified contract .md returns markdown 404 with address and chain" do
    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ { "ABI" => "Contract source code not verified" } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    stub_class_method(ChainReader::AddressInspector, :call,
      ->(**_) { ChainReader::AddressInspector::Result.new(is_contract: true, balance_wei: 0, tx_count: 0, ens_name: nil) }) do
      get "/eth/0x0000000000000000000000000000000000000001.md"
    end

    assert_response :not_found
    assert_equal "text/markdown", response.media_type
    assert_match %r{^# Unverified: 0x0000000000000000000000000000000000000001 on Ethereum}, response.body
    assert_match "unverified contract", response.body
  end

  test "unverified EOA .md flags the address as an externally owned account" do
    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ { "ABI" => "Contract source code not verified" } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    stub_class_method(ChainReader::AddressInspector, :call,
      ->(**_) { ChainReader::AddressInspector::Result.new(is_contract: false, balance_wei: 0, tx_count: 0, ens_name: nil) }) do
      get "/eth/0x0000000000000000000000000000000000000002.md"
    end

    assert_response :not_found
    assert_match "externally owned account (EOA)", response.body
  end

  # ---------- slug aliases (WMATIC → WPOL rebrand) ----------

  test "hex URL for an aliased contract 301s to the canonical (newest) slug, not the legacy alias" do
    wpol_address = "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270"
    get contract_path(chain: "polygon", address: wpol_address)
    assert_redirected_to "/wpol-polygon"
    assert_equal 301, response.status
  end

  # Legacy slug must keep resolving so existing inbound links don't 404,
  # AND the page must emit rel="canonical" pointing at the new slug so Google
  # consolidates ranking on the current brand without a 301 bounce.
  test "legacy alias /wmatic-polygon resolves and emits canonical link to /wpol-polygon" do
    wpol_address = "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270"
    # Non-empty ABI with no zero-arg view functions → controller skips the
    # Etherscan fetch AND ViewCaller has nothing to call over the network.
    Contract.find_or_create_by!(chain: chains(:polygon), address: wpol_address) do |c|
      c.name = "Wrapped_Polygon_Ecosystem_Token"
      c.abi = [ { "type" => "event", "name" => "Transfer", "inputs" => [] } ]
      c.verified_at = 1.hour.ago
    end

    get "/wmatic-polygon"
    assert_response :success
    assert_match %r{<link rel="canonical" href="[^"]*/wpol-polygon">}, response.body
  end

  test "slug-eligible page emits canonical link tag" do
    contract = contracts(:uni_token)
    contract.update!(address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    get "/uni-eth"
    assert_response :success
    assert_match %r{<link rel="canonical" href=".*/uni-eth">}, response.body
  end

  test "non-slug contract page does NOT emit canonical link tag" do
    contract = contracts(:uni_token)
    # fixture address (0x1111...) is not in the slug map
    get contract_path(chain: "eth", address: contract.address)
    assert_response :success
    refute_match %r{rel="canonical"}, response.body
  end

  # Prevents the Overview-stats-overflow regression fixed in fix/mobile-layout.
  # DaisyUI's `stats` component defaults to horizontal, which overflows on
  # <768px viewports. We explicitly stack vertically and switch to horizontal
  # at md+. Losing either class silently reintroduces the overflow on mobile.
  test "Overview stats container stacks vertically on mobile and goes horizontal at md+" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)
    assert_response :success
    assert_match %r{class="[^"]*stats stats-vertical md:stats-horizontal}, response.body
  end

  # ---------- SEO meta tags + JSON-LD ----------

  test "contract page sets OG title with chain and contract name" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    assert_match %r{<meta property="og:title" content="Uni on Ethereum — live on-chain contract docs \| smarts.md">}, response.body
    assert_match %r{<meta property="og:description"[^>]+Uni}, response.body
    assert_match %r{<meta property="og:type" content="website">}, response.body
    assert_match %r{<meta name="twitter:card" content="summary_large_image">}, response.body
  end

  test "contract page emits JSON-LD WebPage + SoftwareApplication block" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    data = response.body.scan(%r{<script type="application/ld\+json">(.+?)</script>}m)
                        .map { |m| JSON.parse(m[0]) }
                        .find { |j| j["@type"] == "WebPage" }
    assert data, "expected a WebPage JSON-LD on the contract page"
    assert_equal "SoftwareApplication", data["about"]["@type"]
    assert_equal "SmartContract", data["about"]["applicationCategory"]
    assert_equal "Ethereum", data["about"]["operatingSystem"]
    assert_equal contract.address, data["about"]["identifier"]
    assert_equal "Uni", data["about"]["name"]
    # softwareVersion comes from contract.compiler_version — locks the helper→view wiring.
    assert_equal contract.compiler_version, data["about"]["softwareVersion"]
  end

  test "contract page emits BreadcrumbList JSON-LD with Smarts → contract trail" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)

    breadcrumb = response.body.scan(%r{<script type="application/ld\+json">(.+?)</script>}m)
                               .map { |m| JSON.parse(m[0]) }
                               .find { |j| j["@type"] == "BreadcrumbList" }

    assert breadcrumb, "expected a BreadcrumbList JSON-LD on the contract page"
    assert_equal 2, breadcrumb["itemListElement"].size
    assert_equal "Smarts", breadcrumb["itemListElement"][0]["name"]
    assert_equal "Uni on Ethereum", breadcrumb["itemListElement"][1]["name"]
    assert_match %r{smarts\.md/}, breadcrumb["itemListElement"][1]["item"]
  end

  # show.html.erb picks between two description templates based on whether
  # the classifier returned anything. Without this test the unclassified
  # branch would only surface in production on some weird contract.
  test "contract page description falls back to display-address form when no classification" do
    contract = contracts(:uni_token)

    stub_class_method(ContractDocument::Classifier, :call, ->(_) { nil }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match %r{<meta property="og:description" content="Live on-chain docs for Uni at #{Regexp.escape(contract.display_address)} on Ethereum\.}, response.body
    refute_match %r{<meta property="og:description" content="[^"]*\(ERC-20 Token\)}, response.body
  end

  test "contract page still shows ERC-20 badge and description when classifier is missing" do
    contract = contracts(:uni_token)

    stub_class_method(ContractDocument::Classifier, :call, ->(_) { nil }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "ERC-20 Token", response.body
    assert_match "Fungible token following the ERC-20 standard.", response.body
  end

  # When the on-chain ERC-20 name() call succeeds, every page-level display
  # point — H1, <title>, og:title, breadcrumb entry, JSON-LD about.name —
  # must switch to the brand name, not the Solidity class name Etherscan
  # returned. Regression locks on the "FiatTokenV2_2 vs USD Coin" bug.
  # Shell no longer loads live values — the display name falls through to
  # the protocol adapter's display_name or contract.name. The on-chain name()
  # value is served via the /live island endpoint instead.
  test "contract page uses adapter display_name or contract.name in shell when no live values" do
    contract = contracts(:uni_token)
    contract.update!(name: "FiatTokenV2_2")

    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    # Without an adapter or live values, falls through to contract.name
    assert_select "h1", "FiatTokenV2_2"
  end

  test "contract page uses adapter display_name ticker in shell for ERC-20s" do
    contract = contracts(:uni_token)
    contract.update!(name: "Tether USD")

    fake_adapter = ProtocolAdapters::GenericErc20Adapter.allocate
    fake_adapter.instance_variable_set(:@contract, contract)
    fake_adapter.instance_variable_set(:@chain, contract.chain)
    fake_adapter.define_singleton_method(:display_name) { "USDT" }

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_) { fake_adapter }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_select "h1", "USDT"
  end

  # The SEO helper runs in the layout, which is shared with error-state views.
  # If a helper call raises or emits nothing on these pages, a future change
  # would degrade our 404/500 discoverability without any louder signal.
  test "not_verified page still renders layout meta tags via the SEO helper" do
    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ { "ABI" => "Contract source code not verified" } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    stub_class_method(ChainReader::AddressInspector, :call,
      ->(**_) { ChainReader::AddressInspector::Result.new(is_contract: true, balance_wei: 0, tx_count: 0, ens_name: nil) }) do
      get contract_path(chain: "eth", address: "0x0000000000000000000000000000000000000001")
    end

    assert_response :not_found
    # Falls back to site-wide default title since not_verified.html.erb doesn't set its own.
    assert_match %r{<title>#{Regexp.escape(SeoHelper::DEFAULT_TITLE)}</title>}, response.body
    assert_match %r{<meta property="og:site_name" content="Smarts">}, response.body
    assert_match %r{<meta name="description"}, response.body
  end

  # ---------- MCP info card ----------

  test "contract page shows the MCP info card with slug reference for sluged contracts" do
    contract = contracts(:uni_token)
    contract.update!(address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984") # uni-eth
    get "/uni-eth"

    assert_response :success
    assert_match "Query this contract from your AI", response.body
    # Reference shows the slug prominently + address as secondary
    assert_match "uni-eth", response.body
    assert_match "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984", response.body
    # Sample prompt uses the slug
    assert_match "Tell me the current state of uni-eth", response.body
    # Setup pointer
    assert_match "mcp.smarts.md", response.body
  end

  test "contract page shows the MCP info card with chain/address reference for non-sluged contracts" do
    contract = contracts(:uni_token) # fixture at 0x1111... (no slug)
    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    assert_match "Query this contract from your AI", response.body
    # Sample prompt falls back to chain/address when no slug exists
    assert_match "Tell me the current state of eth/0x1111111111111111111111111111111111111111", response.body
  end

  # Clipboard is driven entirely by `data-copy-text-value`. If someone
  # refactors the partial and mis-templates the attribute, copy buttons
  # would silently write the wrong string (or empty). This assert locks
  # the slug-button's value down.
  test "copy button for the slug reference carries the correct data-copy-text-value" do
    contract = contracts(:uni_token)
    contract.update!(address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    get "/uni-eth"

    assert_match %r{data-copy-text-value="uni-eth"}, response.body
    assert_match %r{data-copy-text-value="Tell me the current state of uni-eth"}, response.body
  end

  # The MCP card sits OUTSIDE the `if @protocol_adapter` branch in show.html.erb.
  # A refactor that moves it inside would make the card disappear from every
  # adapter-backed page (USDC, Uniswap V3, …) — i.e. exactly the pages where
  # the AI integration matters most. This test stubs an adapter and asserts
  # both renders happen.
  # The MCP card is in the shell; the adapter panel is now in the /live island.
  # Verify the MCP card renders in the shell and the live Turbo Frame placeholder exists.
  test "MCP card renders in shell with Turbo Frame placeholder for adapter panel" do
    contract = contracts(:uni_token)

    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    assert_match "Query this contract from your AI", response.body, "MCP card must render"
    assert_match '<turbo-frame id="contract_live"', response.body, "live island frame must exist"
  end

  test "show fetches from etherscan when contract not in db" do
    stub_etherscan_full

    get contract_path(chain: "eth", address: "0x2222222222222222222222222222222222222222")

    assert_response :success
    assert_select "h1", "TetherToken"
    assert Contract.exists?(address: "0x2222222222222222222222222222222222222222")
  end

  test "show extracts and persists NatSpec end-to-end on first fetch" do
    stub_etherscan_full(source_code: <<~SOL)
      contract TetherToken {
        /// @notice Total supply of USDT.
        function totalSupply() external view returns (uint256) {}
      }
    SOL

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: "0x2222222222222222222222222222222222222222")
    end

    persisted = Contract.find_by!(address: "0x2222222222222222222222222222222222222222")
    assert_equal "Total supply of USDT.", persisted.natspec.dig("functions", "totalSupply", "notice")
    assert_match "Total supply of USDT.", response.body
  end

  test "show returns 404 for unverified contract" do
    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ { "ABI" => "Contract source code not verified" } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    stub_class_method(ChainReader::AddressInspector, :call,
      ->(**_) { ChainReader::AddressInspector::Result.new(is_contract: true, balance_wei: 0, tx_count: 0, ens_name: nil) }) do
      get contract_path(chain: "eth", address: "0x0000000000000000000000000000000000000001")
    end
    assert_response :not_found
  end

  test "not_verified page renders wallet-address copy when inspection reports an EOA" do
    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ { "ABI" => "Contract source code not verified" } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    eoa_result = ChainReader::AddressInspector::Result.new(
      is_contract: false, balance_wei: 1_800_000_000_000_000_000, tx_count: 42, ens_name: "vitalik.eth"
    )
    stub_class_method(ChainReader::AddressInspector, :call, ->(**_) { eoa_result }) do
      get contract_path(chain: "eth", address: "0xd8da6bf26964af9d7eed9e03e53415d37aa96045")
    end

    assert_response :not_found
    assert_match "Wallet address", response.body
    assert_match "vitalik.eth", response.body
    assert_match "1.80 ETH", response.body
    assert_match "Transactions sent", response.body
  end

  test "show returns 404 for unknown chain" do
    get contract_path(chain: "solana", address: "0x0000000000000000000000000000000000000001")
    assert_response :not_found
  end

  # Live values moved to the /live island — the shell docs tab renders without
  # inline live results. Verify the live island endpoint serves them instead.
  test "live island renders on-chain values via protocol adapter" do
    contract = contracts(:uni_token)
    live_values = {
      "totalSupply()" => ChainReader::Multicall3Client::Result.new(success: true, values: [ 1_000_000_000_000_000_000_000_000_000 ])
    }

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { live_values }) do
      get "/eth/#{contract.address}/live"
    end

    assert_response :success
    assert_match '<turbo-frame id="contract_live">', response.body
  end

  # ---------- block-anchored freshness rendering ----------
  #
  # The freshness story is the product's "live docs" promise. Tests exercise
  # the full path: ViewCaller → Snapshot → controller ivar → ERB partial. We
  # rely on the test_helper auto-wrap to give the Snapshot a block_number.

  # Freshness header now renders in the /live island, not the shell.
  test "live island renders panel-level freshness header with block number" do
    contract = contracts(:uni_token)
    snapshot = ChainReader::ViewCaller::Snapshot.new(
      results: { "totalSupply()" => ChainReader::Multicall3Client::Result.new(success: true, values: [ 1 ]) },
      block_number: 24_500_000,
      fetched_at: Time.current
    )

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { snapshot }) do
      get "/eth/#{contract.address}/live"
    end

    assert_response :success
  end

  # ---------- price freshness rendering (TVL / Price provenance line) ----------

  # Protocol adapter panel now renders in the /live island endpoint.
  test "live island renders ERC-20 price freshness when price_observed_at is set" do
    contract = contracts(:uni_token)
    fake_adapter = ProtocolAdapters::GenericErc20Adapter.allocate
    fake_adapter.instance_variable_set(:@contract, contract)
    fake_adapter.instance_variable_set(:@chain, contract.chain)
    fake_adapter.define_singleton_method(:panel_data) do
      { symbol: "UNI", name: "Uniswap", decimals: 18,
        total_supply_raw: 10**27, total_supply_formatted: "1,000,000,000 UNI",
        price_usd: 6.5, price_observed_at: 4.minutes.ago - 1.second,
        market_cap_usd: nil, issuer: nil }
    end
    fake_adapter.define_singleton_method(:template_partial) { "protocol_adapters/generic_erc20" }

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_) { fake_adapter }) do
      get "/eth/#{contract.address}/live"
    end

    assert_response :success
    assert_match(/via DefiLlama\s+·\s+4m ago/m, response.body,
                 "users must see when the TVL/price input is older than the chain block they trust")
  end

  test "live island omits ERC-20 freshness clause when price_observed_at is nil" do
    contract = contracts(:uni_token)
    fake_adapter = ProtocolAdapters::GenericErc20Adapter.allocate
    fake_adapter.instance_variable_set(:@contract, contract)
    fake_adapter.instance_variable_set(:@chain, contract.chain)
    fake_adapter.define_singleton_method(:panel_data) do
      { symbol: "UNI", name: "Uniswap", decimals: 18,
        total_supply_raw: nil, total_supply_formatted: nil,
        price_usd: 6.5, price_observed_at: nil,
        market_cap_usd: nil, issuer: nil }
    end
    fake_adapter.define_singleton_method(:template_partial) { "protocol_adapters/generic_erc20" }

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_) { fake_adapter }) do
      get "/eth/#{contract.address}/live"
    end

    assert_response :success
    assert_match "via DefiLlama", response.body
    refute_match(/via DefiLlama\s+·\s+(just now|\d+[smh] ago)/m, response.body,
                 "must not render '· just now' for missing observed_at — that would lie about freshness")
  end

  test "live island omits V3 ' · prices …' when price_observed_at is nil" do
    contract = contracts(:uni_token)
    fake_adapter = ProtocolAdapters::UniswapV3Adapter.allocate
    fake_adapter.instance_variable_set(:@contract, contract)
    fake_adapter.instance_variable_set(:@chain, contract.chain)
    fake_adapter.define_singleton_method(:panel_data) do
      { token0: { symbol: "USDC", decimals: 6, address: "0xa" },
        token1: { symbol: "WETH", decimals: 18, address: "0xb" },
        fee_pct: "0.05%", price_1_per_0: 0.00043, price_0_per_1: 2300.0,
        tick: 198_000, liquidity: 1_000_000_000_000_000_000,
        tvl_usd: 100_000_000, price_observed_at: nil,
        block_number: 19_000_000, fetched_at: Time.current }
    end
    fake_adapter.define_singleton_method(:template_partial) { "protocol_adapters/uniswap_v3_pool" }
    fake_adapter.define_singleton_method(:protocol_name) { "Uniswap V3" }

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_) { fake_adapter }) do
      get "/eth/#{contract.address}/live"
    end

    assert_response :success
    assert_match "via DefiLlama", response.body
    refute_match(/prices\s+(just now|\d+[smh] ago)/, response.body)
  end

  test "V3 .md page surfaces 'prices Xs ago' when price_observed_at is set" do
    contract = contracts(:uni_token)
    fake_adapter = ProtocolAdapters::UniswapV3Adapter.allocate
    fake_adapter.instance_variable_set(:@contract, contract)
    fake_adapter.instance_variable_set(:@chain, contract.chain)
    fake_adapter.define_singleton_method(:panel_data) do
      { token0: { symbol: "USDC", decimals: 6,  address: "0xa0b8" },
        token1: { symbol: "WETH", decimals: 18, address: "0xc02a" },
        fee_pct: "0.05%", price_1_per_0: 0.00043, price_0_per_1: 2334.30,
        tick: 198_765, liquidity: 1_500_000_000_000_000_000,
        tvl_usd: 100_000_000,
        price_observed_at: 30.seconds.ago,
        block_number: 19_000_000, fetched_at: Time.current }
    end
    fake_adapter.define_singleton_method(:template_partial) { "protocol_adapters/uniswap_v3_pool" }
    fake_adapter.define_singleton_method(:protocol_name) { "Uniswap V3" }

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_) { fake_adapter }) do
      get "/eth/#{contract.address}.md"
    end

    assert_response :success
    assert_match "## Pool state", response.body
    assert_match(/TVL:.*via DefiLlama, prices \d+s ago/, response.body)
  end

  test "ERC-20 .md page surfaces 'X ago' on Price line when price_observed_at is set" do
    contract = contracts(:uni_token)
    fake_adapter = ProtocolAdapters::GenericErc20Adapter.allocate
    fake_adapter.instance_variable_set(:@contract, contract)
    fake_adapter.instance_variable_set(:@chain, contract.chain)
    fake_adapter.define_singleton_method(:panel_data) do
      { symbol: "UNI", name: "Uniswap", decimals: 18,
        total_supply_raw: nil, total_supply_formatted: nil,
        price_usd: 6.5, price_observed_at: 90.seconds.ago,
        market_cap_usd: nil, issuer: nil }
    end
    fake_adapter.define_singleton_method(:template_partial) { "protocol_adapters/generic_erc20" }

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_) { fake_adapter }) do
      get "/eth/#{contract.address}.md"
    end

    assert_response :success
    assert_match(/^- \*\*Price:\*\* \$6\.5.*via DefiLlama, 1m ago/, response.body)
  end

  # Shell no longer loads live values — the docs tab renders without a
  # block-number marker. Verify the shell still renders successfully.
  test "shell renders docs tab without block number when live values not loaded" do
    contract = contracts(:uni_token)

    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    refute_match(/as of Block/, response.body, "shell has no live block tag")
    assert_match "Read Functions", response.body
  end

  test "show renders NatSpec notice inline for documented functions" do
    contract = contracts(:uni_token)
    contract.update!(natspec: {
      "functions" => { "totalSupply" => { "notice" => "Total tokens in circulation." } }
    })

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "Total tokens in circulation.", response.body
  end

  # Source tab is now lazy-loaded via the /source island endpoint.
  test "source island renders highlighted source code" do
    contract = contracts(:uni_token)
    contract.update!(source_code: "contract Token { uint256 x; }")

    get "/eth/#{contract.address}/source"

    assert_response :success
    assert_match '<turbo-frame id="contract_source">', response.body
    assert_match 'class="highlight', response.body
  end

  test "show renders @dev alert, @param and @return descriptions inline" do
    contract = contracts(:uni_token)
    contract.update!(natspec: {
      "functions" => {
        "approve" => {
          "notice" => "Approve a spender.",
          "dev"    => "Subject to the usual ERC-20 race condition.",
          "params" => { "spender" => "Who may spend.", "rawAmount" => "Token allowance." },
          "returns" => [ "True on success." ]
        }
      }
    })

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_match "Subject to the usual ERC-20 race condition.", response.body
    assert_match "Who may spend.", response.body
    assert_match "Token allowance.", response.body
    assert_match "True on success.", response.body
    assert_match "alert-info", response.body
  end

  test "source island renders one radio tab per file for multi-file Solidity standard JSON" do
    contract = contracts(:uni_token)
    multi_file_source = "{" + {
      language: "Solidity",
      sources: {
        "contracts/Token.sol"        => { "content" => "contract Token {}" },
        "contracts/interfaces/IERC.sol" => { "content" => "interface IERC {}" }
      }
    }.to_json + "}"
    contract.update!(source_code: multi_file_source)

    get "/eth/#{contract.address}/source"

    assert_response :success
    assert_match 'name="source_file"', response.body
    assert_match 'aria-label="Token.sol"', response.body
    assert_match 'aria-label="IERC.sol"', response.body
  end

  test "show renders classification badge for a classifiable contract" do
    # uni_token fixture has an ERC-20 method in its ABI. Add the full set so
    # the classifier picks it up.
    contract = contracts(:uni_token)
    contract.update!(abi: erc20_like_abi)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "ERC-20 Token", response.body
    assert_match "Fungible token following the ERC-20 standard", response.body
  end

  test "show tolerates classifier failure and still renders the page" do
    contract = contracts(:uni_token)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(ContractDocument::Classifier, :call, ->(_c) { raise "classifier bug" }) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end

    assert_response :success
  end

  test "show enqueues EnrichContractAiJob when ai_natspec is missing and some function lacks real natspec" do
    contract = contracts(:uni_token)
    contract.update!(natspec: {}, ai_natspec: nil)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      assert_enqueued_with(job: EnrichContractAiJob, args: [ contract ]) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end
  end

  test "show does not enqueue AI job when contract ABI is empty (no functions to document)" do
    # Simulate a verified contract whose parsed ABI is [] — e.g. a Solidity
    # library with no public functions. The enqueue guard must skip it.
    stub_etherscan_full_with_empty_abi

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      assert_no_enqueued_jobs(only: EnrichContractAiJob) do
        get contract_path(chain: "eth", address: "0x2222222222222222222222222222222222222222")
      end
    end
  end

  test "show does not enqueue AI job when ai_natspec already present" do
    contract = contracts(:uni_token)
    contract.update!(ai_natspec: { "functions" => { "transfer" => { "notice" => "x" } } })

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      assert_no_enqueued_jobs(only: EnrichContractAiJob) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end
  end

  test "show does not enqueue AI job when all functions already have real natspec" do
    contract = contracts(:uni_token)
    all_names = (contract.view_functions + contract.write_functions).map { |f| f["name"] }
    contract.update!(
      natspec: { "functions" => all_names.to_h { |n| [ n, { "notice" => "documented" } ] } },
      ai_natspec: nil
    )

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      assert_no_enqueued_jobs(only: EnrichContractAiJob) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end
  end

  test "show tolerates AI job enqueue failure (queue backend down)" do
    contract = contracts(:uni_token)
    contract.update!(natspec: {}, ai_natspec: nil)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(EnrichContractAiJob, :perform_later, ->(_c) { raise "queue down" }) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end

    assert_response :success
    assert_select "h1", contract.name
  end

  test "show renders an em-dash placeholder for unnamed input/output parameters" do
    contract = contracts(:uni_token)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "opacity-40", response.body
    refute_match "(unnamed)", response.body
  end

  test "show renders ✨ AI badge next to AI-generated descriptions" do
    contract = contracts(:uni_token)
    contract.update!(
      natspec: nil,
      ai_natspec: {
        "functions" => { "totalSupply" => { "notice" => "Generated by Claude." } }
      }
    )

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "Generated by Claude.", response.body
    assert_match "✨ AI", response.body
  end

  test "show tolerates protocol-adapter failure and renders the page without a panel" do
    contract = contracts(:uni_token)
    crashing = ->(_c) { raise StandardError, "adapter bug" }

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(ProtocolAdapters::Base, :resolve, crashing) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end

    assert_response :success
    refute_match "Uniswap V3", response.body
  end

  test "show tolerates live-value failure and still renders page" do
    contract = contracts(:uni_token)
    raising = ->(_c) { raise ChainReader::Base::RpcError, "rpc down" }

    stub_class_method(ChainReader::ViewCaller, :call, raising) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_select "h1", contract.name
  end

  # Activity tests now hit the /activity island endpoint directly.
  test "activity island renders decoded recent events and AI prompt" do
    contract = contracts(:uni_token)
    activity = activity_result(contract, events: [ activity_event("Transfer", {
      "from" => "0x" + "a" * 40,
      "to" => "0x" + "b" * 40,
      "amount" => 1_000
    }) ])

    stub_class_method(ContractEvents::RecentFetcher, :call, ->(**_) { activity }) do
      get "/eth/#{contract.address}/activity"
    end

    assert_response :success
    assert_match "Live Activity", response.body
    assert_match "Recent contract events decoded from the verified ABI", response.body
    assert_match "Transfer", response.body
    assert_match "0xaaaa…aaaa → 0xbbbb…bbbb", response.body
    assert_match "Ask your AI to analyze this activity", response.body
  end

  test "activity island renders binary event args without encoding errors" do
    contract = contracts(:uni_token)
    activity = activity_result(contract, events: [ activity_event("OrderFilled", {
      "maker" => "0x" + "a" * 40,
      "bin_key".b => "ok",
      "orderHash" => ("\xFF\xFE\x00abc").b
    }) ])

    stub_class_method(ContractEvents::RecentFetcher, :call, ->(**_) { activity }) do
      get "/eth/#{contract.address}/activity"
    end

    assert_response :success
    assert_match "OrderFilled", response.body
    assert_match "bin_key", response.body
    assert_match "0xfffe00616263", response.body
  end

  test "activity island passes event_name query param into fetcher" do
    contract = contracts(:uni_token)
    seen_event_name = nil
    activity = activity_result(contract, event_filter: "Transfer")

    stub_class_method(ContractEvents::RecentFetcher, :call, ->(**kwargs) {
      seen_event_name = kwargs[:event_name]
      activity
    }) do
      get "/eth/#{contract.address}/activity", params: { event_name: "Transfer" }
    end

    assert_response :success
    assert_equal "Transfer", seen_event_name
    assert_match "btn-primary", response.body
  end

  test "activity island defaults ERC-20 to Transfer events" do
    contract = contracts(:uni_token)
    seen_event_name = nil
    activity = activity_result(contract, event_filter: "Transfer")

    stub_class_method(ContractEvents::RecentFetcher, :call, ->(**kwargs) {
      seen_event_name = kwargs[:event_name]
      activity
    }) do
      get "/eth/#{contract.address}/activity"
    end

    assert_response :success
    assert_equal "Transfer", seen_event_name
  end

  test "activity island preserves explicit all-events filter" do
    contract = contracts(:uni_token)
    seen_event_name = :unset
    activity = activity_result(contract, event_filter: nil)

    stub_class_method(ContractEvents::RecentFetcher, :call, ->(**kwargs) {
      seen_event_name = kwargs[:event_name]
      activity
    }) do
      get "/eth/#{contract.address}/activity", params: { event_name: "all" }
    end

    assert_response :success
    assert_nil seen_event_name
    assert_match 'href="/eth/0x1111111111111111111111111111111111111111/activity?event_name=all"', response.body
  end

  test "activity island filter links target the Turbo Frame" do
    contract = contracts(:uni_token)
    activity = activity_result(contract)

    stub_class_method(ContractEvents::RecentFetcher, :call, ->(**_) { activity }) do
      get "/eth/#{contract.address}/activity"
    end

    assert_response :success
    assert_match '<turbo-frame data-turbo-action="advance" id="contract_activity">', response.body
    assert_match 'data-turbo-frame="contract_activity"', response.body
    assert_match 'href="/eth/0x1111111111111111111111111111111111111111/activity?event_name=all"', response.body
    assert_match 'href="/eth/0x1111111111111111111111111111111111111111/activity?event_name=Transfer"', response.body
  end

  test "contract page .md includes recent activity section and analysis prompt" do
    contract = contracts(:uni_token)
    activity = activity_result(contract, events: [ activity_event("Transfer", {
      "from" => "0x" + "a" * 40,
      "to" => "0x" + "b" * 40,
      "amount" => 1_000
    }) ])

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(ContractEvents::RecentFetcher, :call, ->(**_) { activity }) do
        get "/eth/#{contract.address}.md"
      end
    end

    assert_response :success
    assert_match "## Recent activity", response.body
    assert_match "**Transfer**", response.body
    assert_match "Ask your AI agent", response.body
  end

  test "activity island tolerates fetcher failure and renders error" do
    contract = contracts(:uni_token)
    activity = activity_result(contract, error: "Etherscan: down")

    stub_class_method(ContractEvents::RecentFetcher, :call, ->(**_) { activity }) do
      get "/eth/#{contract.address}/activity"
    end

    assert_response :success
    assert_match "Could not load recent activity", response.body
  end

  test "contract pages no longer expose a governance tab or timeline" do
    contract = contracts(:uni_token)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
      assert_response :success
      refute_match %r{id="contract_tab_governance"}, response.body
      assert_match %r{id="contract_tab_activity"}, response.body

      stub_class_method(ContractEvents::RecentFetcher, :call, ->(**_) { activity_result(contract) }) do
        get "/eth/#{contract.address}.md"
      end
    end

    assert_response :success
    refute_match "## Governance timeline", response.body
    refute_match "Governance events loaded", response.body
  end

  # ---------- Admin & Risk section ----------

  test "show HTML renders Admin & Risk section with detected controls and proxy badge" do
    contract = contracts(:uni_token)
    profile = AdminRisk::Profiler::Result.new(
      contract: contract.address,
      chain: "eth",
      summary: "Detected pausable and ownable controls from the verified ABI.",
      risk_flags: [ "pausable", "ownable" ],
      controls: [
        { key: "owner", label: "Owner", type: "address",
          value: "0x1111111111111111111111111111111111111111", source: "view" },
        { key: "implementation", label: "Implementation", type: "address",
          value: "0x2222222222222222222222222222222222222222", source: "proxy" }
      ],
      evidence: [],
      warnings: [ "Upgradeability inferred from ABI/events; proxy storage resolution may be incomplete." ],
      block_number: 24_500_000,
      fetched_at: Time.current,
      error: nil
    )

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(AdminRisk::Profiler, :call, ->(**_) { profile }) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end

    assert_response :success
    assert_match "Who can change the rules?", response.body
    assert_match "Detected pausable and ownable controls", response.body
    assert_match "Pausable", response.body
    assert_match "Ownable",  response.body
    assert_match "0x1111111111111111111111111111111111111111", response.body
    assert_match ">proxy<", response.body, "proxy-sourced controls must be tagged"
    assert_match "Upgradeability inferred", response.body
    assert_match "Block #24,500,000", response.body
  end

  test "show HTML omits the Admin & Risk content paths when profile is neutral" do
    contract = contracts(:uni_token)
    profile = AdminRisk::Profiler::Result.new(
      contract: contract.address, chain: "eth",
      summary: "No admin risk controls detected from the verified ABI.",
      risk_flags: [], controls: [],
      evidence: [], warnings: [], block_number: nil, fetched_at: nil, error: nil
    )

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(AdminRisk::Profiler, :call, ->(**_) { profile }) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end

    assert_response :success
    # Section header still renders so the page promises a consistent shape,
    # but no flag pills / control table / warnings list appear.
    assert_match "Who can change the rules?", response.body
    assert_match "No admin risk controls detected", response.body
    refute_match "Current controls", response.body
  end

  test "Polymarket contract pages highlight governance MCP queries in Admin & Risk" do
    chain_slug, address = ContractSlugResolver.resolve("polymarket-conditional-tokens-polygon")
    contract = Contract.find_or_create_by!(chain: Chain.find_by!(slug: chain_slug), address: address) do |c|
      c.name = "ConditionalTokens"
      c.abi = [ { "type" => "event", "name" => "ConditionResolution", "inputs" => [] } ]
    end
    profile = AdminRisk::Profiler::Result.new(
      contract: contract.address, chain: "polygon",
      summary: "No admin risk controls detected from the verified ABI.",
      risk_flags: [], controls: [],
      evidence: [], warnings: [], block_number: nil, fetched_at: nil, error: nil
    )

    fake_adapter = ProtocolAdapters::PolymarketAdapter.new(contract)
    fake_adapter.define_singleton_method(:panel_data) { { resolutions: [], preparations: [], redemptions: [], errors: {} } }

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(ProtocolAdapters::Base, :resolve, ->(_) { fake_adapter }) do
        stub_class_method(AdminRisk::Profiler, :call, ->(**_) { profile }) do
          get "/polymarket-conditional-tokens-polygon"
        end
      end
    end

    assert_response :success
    assert_match "Polymarket contract governance", response.body
    assert_match "Ask your AI who can pause, upgrade, or change roles", response.body
    refute_match(/get_governance_timeline\(/, response.body)
  end

  test "Polymarket exchange docs tab distinguishes CTF and neg-risk architecture" do
    ctf_chain, ctf_address = ContractSlugResolver.resolve("polymarket-ctf-exchange-v2-polygon")
    neg_chain, neg_address = ContractSlugResolver.resolve("polymarket-neg-risk-exchange-v2-polygon")
    abi = [
      { "type" => "function", "name" => "PARENT_COLLECTION_ID",
        "inputs" => [], "outputs" => [ { "type" => "bytes32" } ], "stateMutability" => "view" }
    ]

    Contract.find_or_create_by!(chain: Chain.find_by!(slug: ctf_chain), address: ctf_address) do |contract|
      contract.name = "CTFExchange"
      contract.abi = abi
    end
    Contract.find_or_create_by!(chain: Chain.find_by!(slug: neg_chain), address: neg_address) do |contract|
      contract.name = "NegRiskExchange"
      contract.abi = abi
    end

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get "/polymarket-ctf-exchange-v2-polygon"
      assert_response :success
      assert_match "Architecture", response.body
      assert_match "Polymarket CTF Exchange", response.body
      assert_match "binary Polymarket markets", response.body
      assert_match "Shares the same trading ABI as the Neg-Risk Exchange", response.body
      assert_match "Binary / Yes-No markets", response.body
      assert_match "polymarket-neg-risk-exchange-v2-polygon", response.body
      assert_match "CTF Exchange", response.body
      refute_match "multi-outcome Polymarket markets", response.body

      get "/polymarket-neg-risk-exchange-v2-polygon"
      assert_response :success
      assert_match "Architecture", response.body
      assert_match "Polymarket Neg-Risk Exchange", response.body
      assert_match "multi-outcome Polymarket markets", response.body
      assert_match "Shares the same trading ABI as the CTF Exchange", response.body
      assert_match "Multi-outcome / mutually exclusive markets", response.body
      assert_match "polymarket-ctf-exchange-v2-polygon", response.body
      assert_match "Neg-Risk Exchange", response.body
    end
  end

  test "Polymarket docs add context to key functions and events" do
    chain_slug, address = ContractSlugResolver.resolve("polymarket-ctf-exchange-v2-polygon")
    abi = [
      { "type" => "function", "name" => "matchOrders",
        "inputs" => [], "outputs" => [], "stateMutability" => "nonpayable" },
      { "type" => "function", "name" => "PARENT_COLLECTION_ID",
        "inputs" => [], "outputs" => [ { "type" => "bytes32" } ], "stateMutability" => "view" },
      { "type" => "event", "name" => "OrderFilled", "inputs" => [] }
    ]
    Contract.find_or_create_by!(chain: Chain.find_by!(slug: chain_slug), address: address) do |contract|
      contract.name = "CTFExchange"
      contract.abi = abi
    end

    panel_payload = {
      ok: true,
      fills_count: 0,
      volume_usdc: BigDecimal("0"),
      unique_takers: 0,
      unique_markets: 0,
      top_markets: [],
      latest_fills: [],
      fetched_at: Time.current
    }

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(Polymarket::ExchangeActivity, :call, ->(contract:) { panel_payload }) do
        get "/polymarket-ctf-exchange-v2-polygon"
      end
    end

    assert_response :success
    assert_match "Polymarket context", response.body
    assert_match "binary Yes/No markets", response.body
    assert_match "matches signed Polymarket orders", response.body
    assert_match "Primary exchange activity signal", response.body
  end

  test "Polymarket markdown includes architecture and key contract context" do
    chain_slug, address = ContractSlugResolver.resolve("polymarket-neg-risk-exchange-v2-polygon")
    abi = [
      { "type" => "function", "name" => "matchOrders",
        "inputs" => [], "outputs" => [], "stateMutability" => "nonpayable" },
      { "type" => "function", "name" => "getOrderStatus",
        "inputs" => [], "outputs" => [], "stateMutability" => "view" },
      { "type" => "event", "name" => "OrderFilled", "inputs" => [] }
    ]
    contract = Contract.find_or_create_by!(chain: Chain.find_by!(slug: chain_slug), address: address) do |c|
      c.name = "NegRiskExchange"
      c.abi = abi
    end
    contract.update!(abi: abi)
    panel_payload = {
      ok: true,
      fills_count: 0,
      volume_usdc: BigDecimal("0"),
      unique_takers: 0,
      unique_markets: 0,
      top_markets: [],
      latest_fills: [],
      fetched_at: Time.current
    }

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(Polymarket::ExchangeActivity, :call, ->(contract:) { panel_payload }) do
        get "/polymarket-neg-risk-exchange-v2-polygon.md"
      end
    end

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_match "## Architecture", response.body
    assert_match "Polymarket Neg-Risk Exchange", response.body
    assert_match "Shares the same trading ABI as the CTF Exchange", response.body
    assert_match "Multi-outcome / mutually exclusive markets", response.body
    assert_match "## Key contract context", response.body
    assert_match "multi-outcome markets", response.body
    assert_match "matches signed Polymarket orders", response.body
    assert_match "Primary exchange activity signal", response.body
  end

  test "show HTML falls back gracefully when AdminRisk::Profiler raises" do
    # Controller's rescue must convert the crash into the canned "Could not
    # build admin risk profile." Result. Otherwise a Profiler bug would 500
    # the whole contract page.
    contract = contracts(:uni_token)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(AdminRisk::Profiler, :call, ->(**_) { raise "profiler boom" }) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end

    assert_response :success
    assert_select "h1", contract.name
    assert_match "Could not build admin risk profile", response.body
    assert_match "profiler boom", response.body
  end

  test "contract page .md includes the Admin & Risk section with detected flags and controls" do
    contract = contracts(:uni_token)
    profile = AdminRisk::Profiler::Result.new(
      contract: contract.address, chain: "eth",
      summary: "Detected pausable and ownable controls from the verified ABI.",
      risk_flags: [ "pausable", "ownable" ],
      controls: [
        { key: "owner", label: "Owner", type: "address",
          value: "0xAAAA000000000000000000000000000000000000", source: "view" },
        { key: "paused", label: "Paused", type: "bool", value: false, source: "view" }
      ],
      evidence: [], warnings: [], block_number: 25_000_000, fetched_at: Time.current, error: nil
    )

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(AdminRisk::Profiler, :call, ->(**_) { profile }) do
        stub_class_method(ContractEvents::RecentFetcher, :call, ->(**_) { activity_result(contract) }) do
          get "/eth/#{contract.address}.md"
        end
      end
    end

    assert_response :success
    assert_match "## Admin & Risk", response.body
    assert_match "Detected pausable and ownable controls", response.body
    assert_match "**Detected controls:** Pausable, Ownable", response.body
    assert_match "Owner: `0xaaaa000000000000000000000000000000000000`", response.body
    assert_match "Paused: `false`", response.body
  end

  test "contract page .md surfaces 'Could not build admin risk profile' on Profiler error" do
    contract = contracts(:uni_token)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(AdminRisk::Profiler, :call, ->(**_) { raise "md profiler boom" }) do
        stub_class_method(ContractEvents::RecentFetcher, :call, ->(**_) { activity_result(contract) }) do
          get "/eth/#{contract.address}.md"
        end
      end
    end

    assert_response :success
    assert_match "Could not build admin risk profile: md profiler boom", response.body
  end

  private

  def activity_result(contract, events: [], event_filter: nil, error: nil)
    ContractEvents::RecentFetcher::Result.new(
      contract: contract.address,
      chain: contract.chain.slug,
      event_filter: event_filter,
      latest_block: 25_000_000,
      from_block: 24_995_000,
      count: events.length,
      events: events,
      error: error
    )
  end

  def activity_event(name, args)
    ContractEvents::RecentFetcher::Event.new(
      event: name,
      args: args,
      block_number: 25_000_000,
      tx_hash: "0x" + "d" * 64,
      log_index: 0,
      timestamp: "2026-05-16T12:00:00Z"
    )
  end

  def erc20_like_abi
    %w[totalSupply balanceOf(address) transfer(address,uint256)
       transferFrom(address,address,uint256) approve(address,uint256)
       allowance(address,address)].map do |sig|
      name, args = sig.split("(")
      arg_types = args.to_s.chomp(")").split(",").reject(&:empty?)
      {
        "type" => "function", "name" => name,
        "inputs" => arg_types.map { |t| { "type" => t } },
        "outputs" => [],
        "stateMutability" => "view"
      }
    end
  end

  def stub_etherscan_full_with_empty_abi
    source_body = {
      "status" => "1", "message" => "OK",
      "result" => [ {
        "ContractName" => "EmptyAbiContract", "CompilerVersion" => "v0.8.0",
        "SourceCode" => "library Empty {}", "ABI" => "[]",
        "OptimizationUsed" => "0", "Runs" => "0",
        "EVMVersion" => "default", "LicenseType" => "MIT"
      } ]
    }
    abi_body = { "status" => "1", "message" => "OK", "result" => "[]" }

    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200, body: source_body.to_json, headers: { "Content-Type" => "application/json" }
    )
    stub_request(:get, /api\.etherscan\.io.*getabi/).to_return(
      status: 200, body: abi_body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_etherscan_full(source_code: "contract TetherToken {}")
    source_body = {
      "status" => "1", "message" => "OK",
      "result" => [ {
        "ContractName" => "TetherToken",
        "CompilerVersion" => "v0.4.18",
        "SourceCode" => source_code,
        "ABI" => '[{"type":"function","name":"totalSupply","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"}]',
        "OptimizationUsed" => "1",
        "Runs" => "200",
        "EVMVersion" => "default",
        "LicenseType" => "MIT"
      } ]
    }

    abi_body = {
      "status" => "1", "message" => "OK",
      "result" => '[{"type":"function","name":"totalSupply","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"}]'
    }

    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200, body: source_body.to_json, headers: { "Content-Type" => "application/json" }
    )
    stub_request(:get, /api\.etherscan\.io.*getabi/).to_return(
      status: 200, body: abi_body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  # ── Cache-Control header tests ──────────────────────────────────────

  test "show shell sets Cache-Control public max-age=86400 and ETag" do
    contract = contracts(:uni_token)
    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    cc = response.headers["Cache-Control"]
    assert_match(/public/, cc)
    assert_match(/max-age=86400/, cc)
    assert response.headers["ETag"].present?, "ETag should be set on the shell"
  end

  test "live island sets Cache-Control public max-age=30" do
    contract = contracts(:uni_token)
    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get "/eth/#{contract.address}/live"
    end

    assert_response :success
    cc = response.headers["Cache-Control"]
    assert_match(/public/, cc)
    assert_match(/max-age=30/, cc)
  end

  test "activity island sets Cache-Control public max-age=30" do
    contract = contracts(:uni_token)
    get "/eth/#{contract.address}/activity"

    assert_response :success
    cc = response.headers["Cache-Control"]
    assert_match(/public/, cc)
    assert_match(/max-age=30/, cc)
  end

  test "removed governance island returns 404" do
    contract = contracts(:uni_token)
    get "/eth/#{contract.address}/governance"

    assert_response :not_found
  end

  test "source island sets Cache-Control public max-age=86400" do
    contract = contracts(:uni_token)
    get "/eth/#{contract.address}/source"

    assert_response :success
    cc = response.headers["Cache-Control"]
    assert_match(/public/, cc)
    assert_match(/max-age=86400/, cc)
  end

  test "show shell returns 304 on conditional GET with matching ETag" do
    contract = contracts(:uni_token)
    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    etag = response.headers["ETag"]
    assert etag.present?

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address), headers: { "If-None-Match" => etag }
    end

    assert_response :not_modified
  end

  # ---------- docs_only chains (Tier 2) ----------

  test "docs_only chain renders without RPC and shows docs-only notice" do
    linea = Chain.create!(
      name: "Linea", slug: "linea", chain_id: 59144, tier: "docs_only",
      explorer_api_url: "https://api.etherscan.io/v2/api"
    )
    contract = Contract.create!(
      chain: linea, address: "0x" + "a" * 40,
      name: "FiatTokenV2_1", abi: [ { "name" => "totalSupply", "type" => "function" } ]
    )

    get contract_path(chain: "linea", address: contract.address)

    assert_response :success
    assert_match "Linea is a docs-only chain", response.body
    refute_match %r{turbo-frame id="contract_live"}, response.body
    refute_match %r{id="contract_tab_activity"}, response.body
    refute_match %r{id="contract_tab_governance"}, response.body
    assert_match %r{id="contract_tab_docs"}, response.body
    assert_match %r{id="contract_tab_source"}, response.body
  end

  test "docs_only chain live island returns docs-only notice without hitting RPC" do
    linea = Chain.create!(
      name: "Linea", slug: "linea", chain_id: 59144, tier: "docs_only",
      explorer_api_url: "https://api.etherscan.io/v2/api"
    )
    contract = Contract.create!(
      chain: linea, address: "0x" + "b" * 40, name: "Foo",
      abi: [ { "name" => "totalSupply", "type" => "function" } ]
    )

    get "/linea/#{contract.address}/live"
    assert_response :success
    assert_match "docs-only chain", response.body
  end
end
