require "test_helper"

class MarketingControllerTest < ActionDispatch::IntegrationTest
  setup do
    Chains::Seeder.call
  end

  test "home renders successfully with the hero" do
    get root_path
    assert_response :success
    assert_match "smarts.md", response.body
    assert_match "Live docs for every smart contract.", response.body
  end

  test "home hides nav links but shows the locale switcher" do
    get root_path
    assert_response :success

    refute_match ">Articles<", response.body
    refute_match ">My<", response.body
    assert_match ">EN<", response.body
  end

  # Prevents the mobile-overflow regression fixed in fix/mobile-layout: flex
  # items with unbreakable descendants (long hex addresses, <pre> source
  # blocks) can expand past the viewport on narrow screens. overflow-x-hidden
  # on <body> is the safety net. Applies to the shared layout so every page
  # inherits the same protection.
  test "body carries overflow-x-hidden so mobile never horizontal-scrolls the page" do
    get root_path
    assert_response :success
    assert_match %r{<body[^>]*class="[^"]*overflow-x-hidden}, response.body
  end

  test "home surfaces MCP entry link to mcp.smarts.md" do
    get root_path
    assert_response :success
    assert_match %r{<a href="https://mcp\.smarts\.md/"[^>]*>connect your AI agent</a>}, response.body
  end

  test "home surfaces a chains entry button" do
    get root_path

    assert_response :success
    assert_match %r{<a href="/chains"[^>]*>.*?Browse chains.*?</a>}m, response.body
  end

  test "chains index renders the catalog" do
    get "/chains"

    assert_response :success
    assert_match "Supported chains", response.body
    assert_match "Ethereum", response.body
    assert_match "Linea", response.body
    assert_match "Docs only", response.body
    assert_match "All networks", response.body
  end

  test "chains index filters by search term and tier" do
    get "/chains", params: { q: "PancakeSwap", tier: "full" }

    assert_response :success
    assert_match "BNB Smart Chain", response.body
    refute_match "Ethereum", response.body
    refute_match "Linea", response.body
  end

  test "chains index filters by network" do
    get "/chains", params: { network: "mainnet" }

    assert_response :success
    assert_match "Mainnets", response.body
    assert_match "Ethereum", response.body
  end

  test "testnets route renders the testnet directory shell" do
    get "/testnets"

    assert_response :success
    assert_match "Testnet directory", response.body
    assert_match "Supported testnets", response.body
    assert_match "RPC", response.body
    assert_match "Explorer", response.body
    assert_match "Faucet", response.body
    assert_match "Verify", response.body
    assert_match 'href="https://testnet.monadvision.com"', response.body
    assert_match 'href="https://testnet.stablescan.xyz"', response.body
  end

  test "chain detail renders the contract catalog" do
    get "/chains/eth"

    assert_response :success
    assert_match "Ethereum", response.body
    assert_match "USD Coin", response.body
    assert_match "Wrapped Ether", response.body
    assert_match "/chains/eth.md", response.body
  end

  test "docs-only chain pages use docs-oriented wording" do
    get "/chains/celo"

    assert_response :success
    assert_match "Indexed source, ABI, and contract references.", response.body
    assert_match "Indexed", response.body
  end

  test "chain pages without contracts omit the contracts heading" do
    get "/chains/sepolia"

    assert_response :success
    refute_match(/>Contracts<\/h2>/, response.body)
  end

  test "chain markdown renders an AI-friendly summary" do
    get "/chains/eth.md"

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_match "# Ethereum", response.body
    assert_match "## Query via AI agent", response.body
    assert_match "## Contracts", response.body
  end

  test "localized chain markdown routes work" do
    get "/cn/chains/eth.md"

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_match "# Ethereum", response.body
  end

  test "localized chains URLs render the localized catalog" do
    get "/cn/chains"

    assert_response :success
    assert_match "支持的链", response.body
    assert_match %r{href="/cn/chains/eth"}, response.body
  end

  test "polymarket page uses natural-language AI prompts, not tool call syntax" do
    market = PolymarketClient::Market.new(
      condition_id: "0x" + ("12" * 32),
      slug: "will-example-happen",
      question: "Will example happen?",
      outcomes: [ "Yes", "No" ],
      clob_token_ids: [ "101", "202" ],
      tokens: [
        PolymarketClient::Token.new(outcome: "Yes", token_id: "101", price: BigDecimal("0.6")),
        PolymarketClient::Token.new(outcome: "No", token_id: "202", price: BigDecimal("0.4"))
      ],
      active: true,
      closed: false,
      neg_risk: false,
      volume_num: BigDecimal("1000")
    )

    stub_class_method(PolymarketClient, :fetch_top_markets, ->(limit:) { [ market ] }) do
      stub_class_method(PolymarketClient, :fetch_live_prices, ->(_token_ids) { {} }) do
        get "/polymarket"
      end
    end

    assert_response :success
    assert_match "Ask Your AI", response.body
    assert_match "Audit how this market resolved on-chain", response.body
    refute_match(/get_polymarket_\w+\(/, response.body)
    refute_match(/read_contract_state\(/, response.body)
    refute_match(/get_governance_timeline\(/, response.body)
  end

  # Declares the homepage search form to Google so the sitelinks searchbox
  # becomes eligible on brand queries. If this JSON-LD is lost, the searchbox
  # quietly stops appearing — no error, just missing SERP surface area.
  # Guards the default OG card. If someone deletes the PNG (or the SVG build
  # step goes out of sync), every social share silently loses its card. Path
  # is derived from the helper constant so renaming one without the other
  # fails the test — no silent orphan file.
  test "og-default.png asset is served at the URL the SEO helper advertises" do
    path = URI.parse(SeoHelper::DEFAULT_OG_IMAGE).path
    get path

    assert_response :success
    assert_equal "image/png", response.media_type
    # PNG magic header: 8 bytes starting with 89 50 4E 47 (‰PNG)
    assert_equal "\x89PNG".b, response.body.byteslice(0, 4)
  end

  test "home emits WebSite + SearchAction JSON-LD so Google's sitelinks searchbox is eligible" do
    get root_path
    assert_response :success

    website = response.body.scan(%r{<script type="application/ld\+json">(.+?)</script>}m)
                           .map { |m| JSON.parse(m[0]) }
                           .find { |j| j["@type"] == "WebSite" }

    assert website, "expected a WebSite JSON-LD on the home page"
    assert_equal "SearchAction", website["potentialAction"]["@type"]
    assert_match(/\{search_term_string\}/, website["potentialAction"]["target"]["urlTemplate"])
  end

  test "home emits an ItemList JSON-LD for the top curated contract URLs" do
    get root_path
    assert_response :success

    item_list = response.body.scan(%r{<script type="application/ld\+json">(.+?)</script>}m)
                            .map { |m| JSON.parse(m[0]) }
                            .find { |j| j["@type"] == "ItemList" }

    assert item_list, "expected an ItemList JSON-LD on the home page"
    assert_equal 50, item_list["numberOfItems"]
    assert_equal "https://smarts.md/usdc-eth", item_list["itemListElement"].first["item"]
  end

  test "home localizes featured contract URLs and JSON-LD when the locale cookie is set" do
    Article.create!(
      slug: "1c",
      user: users(:one),
      category: "company",
      subcategory: "updates",
      title: { "en" => "English update", "zh-CN" => "中文更新" },
      summary: { "en" => "English summary", "zh-CN" => "中文摘要" },
      content: { "en" => "English body", "zh-CN" => "中文正文" },
      published_at: Time.current
    )

    cookies[:locale] = "cn"
    get root_path

    assert_response :success
    assert_match %r{href="/cn/usdc-eth"[^>]*>.*?<div class="mb-1 text-sm text-slate-300">USD Coin</div>}m, response.body
    assert_match %r{href="/cn/articles"[^>]*>浏览所有文章</a>}, response.body
    assert_match "Circle 发行的受监管美元稳定币，流动性深厚。", response.body
    refute_match "Circle's regulated USD stablecoin", response.body
    refute_match "largest by market cap", response.body
    refute_match "按市值计规模最大", response.body

    item_list = response.body.scan(%r{<script type="application/ld\+json">(.+?)</script>}m)
                            .map { |m| JSON.parse(m[0]) }
                            .find { |j| j["@type"] == "ItemList" }

    assert item_list, "expected an ItemList JSON-LD on the home page"
    assert_equal "https://smarts.md/cn/usdc-eth", item_list["itemListElement"].first["item"]
  end

  test "home renders the curated featured section" do
    get root_path
    assert_response :success

    # Section header
    assert_match "Or start from a curated blue chip", response.body

    # All four category headers
    %w[Stablecoins Governance Multi-chain].each do |heading|
      assert_match heading, response.body, "expected category heading #{heading.inspect}"
    end
    assert_match "DEX", response.body # matches "DEX & Wrapped"
    assert_match "BNB Smart Chain", response.body

    # Spot-check a few featured items render as clickable links. Items with
    # a slug link via `/{slug}`, items without link via `/{chain}/{address}`.
    MarketingController::FEATURED.sample(3).each do |item|
      slug = ContractSlugResolver.for(item[:chain], item[:address])
      expected_href = slug ? "/#{slug}" : "/#{item[:chain]}/#{item[:address]}"
      assert_match expected_href, response.body,
                   "expected link to #{expected_href} on home page"
    end
  end

  test "home featured cards show ticker titles with human-readable subtitles" do
    get root_path
    assert_response :success

    {
      "usdc-eth" => "USD Coin",
      "usdt-eth" => "Tether USD",
      "dai-eth" => "Dai",
      "uni-eth" => "Uniswap",
      "link-eth" => "Chainlink",
      "aave-eth" => "Aave",
      "usdc-base" => "USD Coin (Base)",
      "usdc-arbitrum" => "USD Coin (Arbitrum)",
      "usdt-bnb" => "Tether USD (BNB)",
      "wbnb-bnb" => "Wrapped BNB",
      "cake-bnb" => "PancakeSwap",
      "wpol-polygon" => "Wrapped POL"
    }.each do |slug, subtitle|
      assert_match %r{href="/#{slug}"[^>]*>.*?<div class="mb-1 text-sm text-slate-300">#{Regexp.escape(subtitle)}</div>}m,
                   response.body
    end
  end

  test "sitemap.xml exposes the top 50 canonical contract URLs" do
    Article.create!(
      slug: "1z",
      user: users(:one),
      category: "company",
      subcategory: "updates",
      title: { "en" => "Sitemap article", "zh-CN" => "站点地图文章" },
      summary: { "en" => "Summary", "zh-CN" => "摘要" },
      content: { "en" => "English body", "zh-CN" => "中文正文" },
      published_at: 1.day.ago
    )

    get "/sitemap.xml"

    assert_response :success
    assert_equal "application/xml", response.media_type

    urls = response.body.scan(%r{<loc>([^<]+)</loc>}).flatten
    expected_length = 50 + Article.published.first.available_locales.length + 1 + Chain.for_display.length
    assert_equal expected_length, urls.length
    assert_equal "https://smarts.md/usdc-eth", urls.first
    refute_includes urls, "https://smarts.md/wmatic-polygon"
    assert_includes urls, "https://smarts.md/1z"
    assert_includes urls, "https://smarts.md/cn/1z"
    assert_includes urls, "https://smarts.md/chains"
    assert_includes urls, "https://smarts.md/chains/eth"
  end

  test "robots.txt advertises the sitemap" do
    get "/robots.txt"

    assert_response :success
    assert_match "Sitemap: https://smarts.md/sitemap.xml", response.body
  end

  test "home redirects q= input with chain/address pattern to the canonical contract URL" do
    get root_path, params: { q: "eth/0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" }
    assert_redirected_to "/usdc-eth"
  end

  test "home redirects q= input to the localized canonical contract URL when a locale cookie is set" do
    cookies[:locale] = "cn"
    get root_path, params: { q: "eth/0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" }
    assert_redirected_to "/cn/usdc-eth"
  end

  # Structural guards on the FEATURED constant — catches typos, wrong chain
  # slugs, malformed addresses before they hit production.

  test "every FEATURED entry has a supported chain slug" do
    supported = Chain.pluck(:slug)
    MarketingController::FEATURED.each do |item|
      assert_includes supported, item[:chain],
                      "FEATURED entry #{item[:symbol]} uses unsupported chain #{item[:chain].inspect}"
    end
  end

  test "every FEATURED address is lowercase 0x + 40 hex" do
    MarketingController::FEATURED.each do |item|
      assert_match(/\A0x[0-9a-f]{40}\z/, item[:address],
                   "malformed address for #{item[:symbol]}: #{item[:address]}")
    end
  end

  test "no duplicate (chain, address) pairs in FEATURED" do
    pairs = MarketingController::FEATURED.map { |i| [ i[:chain], i[:address] ] }
    assert_equal pairs.length, pairs.uniq.length, "duplicate featured contract"
  end

  test "every FEATURED entry has all required keys populated" do
    required = %i[category chain address symbol name blurb]
    MarketingController::FEATURED.each do |item|
      required.each do |key|
        assert item[key].to_s.strip.present?,
               "FEATURED entry #{item[:symbol] || item[:address]} is missing #{key}"
      end
    end
  end

  test "every FEATURED chain has a display label in Chain.labels" do
    featured_chains = MarketingController::FEATURED.map { |i| i[:chain] }.uniq
    missing = featured_chains - Chain.labels.keys
    assert_empty missing, "chains in FEATURED but not in Chain.labels: #{missing.inspect}"
  end

  test "every distinct FEATURED category renders as a heading on the page" do
    get root_path
    assert_response :success

    categories = MarketingController::FEATURED.map { |i| i[:category] }.uniq
    categories.each do |cat|
      # Rails HTML-escapes category names (e.g. "DEX & Wrapped" → "DEX &amp; Wrapped")
      expected = CGI.escapeHTML(cat)
      assert_match expected, response.body,
                   "expected category heading #{cat.inspect} on home page"
    end
  end

  test "home does NOT redirect on malformed q= values" do
    [ "hello", "eth/notahex", "eth/0x123", "/../etc/passwd" ].each do |bad|
      get root_path, params: { q: bad }
      assert_response :success, "should render home, not redirect, for q=#{bad.inspect}"
    end
  end

  # ---------- mcp_docs page (host-constrained to mcp.smarts.md) ----------

  test "mcp_docs renders for requests to the mcp.smarts.md host" do
    host! "mcp.smarts.md"
    get "/"

    assert_response :success
    assert_match "Point your AI at smarts.md", response.body
    assert_match "https://smarts.md/mcp", response.body
    assert_match %r{href="/chains"[^>]*>\s*Browse chains\s*</a>}m, response.body
    assert_match "Quick install", response.body
    assert_match "claude mcp add", response.body
    assert_match "Ask your AI", response.body
    assert_match "Tools", response.body
    assert_match %r{href="/chains"[^>]*>Browse chains</a>}, response.body
  end

  test "mcp_docs also renders for the mcp.localhost local-dev alias" do
    host! "mcp.localhost"
    get "/"

    assert_response :success
    assert_match "Point your AI at smarts.md", response.body
  end

  # Guards the seo_meta migration from content_for :title. If someone reverts
  # mcp_docs.html.erb to the old `content_for :title, "..."` form, the layout
  # will silently fall back to the site-wide default title (since the layout
  # now reads :page_title, not :title).
  test "mcp_docs page emits its own title and description via seo_meta" do
    host! "mcp.smarts.md"
    get "/"

    assert_match %r{<title>Connect your AI \| smarts.md</title>}, response.body
    assert_match %r{<meta property="og:title" content="Connect your AI \| smarts.md">}, response.body
    assert_match %r{<meta name="description" content="One MCP endpoint[^"]+Claude Code[^"]+">}, response.body
  end

  test "mcp_docs does NOT render for arbitrary other subdomains" do
    host! "random.smarts.md"
    get "/"

    # Route doesn't match → falls through to marketing#home or 404
    refute_match "Point your AI at smarts.md", response.body
  end

  test "mcp_docs lists every MCP tool exposed by the app" do
    host! "mcp.smarts.md"
    get "/"

    MarketingController::MCP_TOOLS.each do |tool|
      assert_match tool[:name], response.body, "expected tool #{tool[:name]} on mcp_docs"
    end
  end

  test "mcp_docs explains on-chain native Polymarket verification without tool mapping snippets" do
    host! "mcp.smarts.md"
    get "/"

    assert_response :success
    assert_match "On-chain native", response.body
    assert_match "Audit how a Polymarket market resolved on-chain", response.body
    assert_match "final payout vector", response.body
    refute_match(/read_contract_state\(/, response.body)
    refute_match(/get_polymarket_resolution\(/, response.body)
  end

  test "smarts.md root still renders the marketing home (not mcp_docs)" do
    host! "smarts.md"
    get "/"

    assert_response :success
    assert_match "Live docs for every smart contract.", response.body
    refute_match "Point your AI at smarts.md", response.body,
                 "main domain must not leak the mcp_docs hero"
  end

  test "mcp_docs exposes all the tools defined in app/tools/" do
    app_tool_names = Dir.glob(Rails.root.join("app/tools/*_tool.rb"))
                        .reject { |p| p.include?("application_tool") }
                        .map { |p| File.basename(p, "_tool.rb") }

    documented = MarketingController::MCP_TOOLS.map { |t| t[:name] }
    missing = app_tool_names - documented
    assert_empty missing, "tools present in app/tools but not on mcp_docs: #{missing.inspect}"
  end

  # Catches example-query → tool-name drift. If someone renames a tool in
  # MCP_TOOLS but forgets to update the example, the page would point to a
  # phantom tool. Structural guard, not runtime check.
  test "every MCP_EXAMPLE_QUERIES entry references a known tool" do
    known_tools = MarketingController::MCP_TOOLS.map { |t| t[:name] }
    MarketingController::MCP_EXAMPLE_QUERIES.each do |ex|
      assert_includes known_tools, ex[:tool],
                      "example query #{ex[:q].inspect} references unknown tool #{ex[:tool].inspect}"
    end
  end

  # Production-critical guard: the host-constrained root route MUST NOT
  # shadow the Streamable HTTP MCP transport mounted at /mcp. If it ever
  # does, AI clients hitting mcp.smarts.md/mcp would get the marketing
  # HTML page instead of an MCP JSON-RPC response, and nobody would know
  # until agents silently fail to initialize.
  #
  # The transport accepts POST (JSON-RPC requests), GET (optional SSE
  # stream), and DELETE (session termination). We POST an `initialize`
  # to prove the mount is live and the route ordering is correct.
  test "MCP transport still serves /mcp on the mcp.smarts.md host (not shadowed by marketing)" do
    host! "mcp.smarts.md"
    payload = {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-03-26",
        capabilities: {},
        clientInfo: { name: "rails-test", version: "0" }
      }
    }.to_json

    post "/mcp", params: payload,
                 headers: { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }

    refute_match "Point your AI at smarts.md", response.body,
                 "the MCP endpoint path must not render the marketing docs page"
    assert_match(/jsonrpc/, response.body,
                 "MCP transport should respond with JSON-RPC, proving it's still mounted ahead of the marketing route")
  end

  # ---------- .well-known/mcp.json manifest ----------

  test "well-known MCP manifest returns a JSON payload with top-level fields" do
    get "/.well-known/mcp.json"

    assert_response :success
    assert_equal "application/json; charset=utf-8", response.media_type + "; charset=#{response.charset}"

    body = JSON.parse(response.body)
    assert_equal "smarts", body["name"]
    assert body["version"].present?
    assert body["description"].present?
    assert_equal "https://smarts.md/", body["homepage_url"]
    assert_equal "https://mcp.smarts.md/", body["documentation_url"]
  end

  test "well-known MCP manifest advertises the Streamable HTTP transport with the canonical endpoint" do
    get "/.well-known/mcp.json"
    body = JSON.parse(response.body)

    streamable = body["transports"].find { |t| t["type"] == "streamable-http" }
    assert streamable, "expected a transport of type streamable-http"
    assert_equal "https://smarts.md/mcp", streamable["endpoint"]

    assert_equal "2025-03-26", body["protocol_version"]
  end

  test "well-known MCP manifest lists every MCP tool with its description" do
    get "/.well-known/mcp.json"
    body = JSON.parse(response.body)

    listed_names = body["tools"].map { |t| t["name"] }
    expected     = MarketingController::MCP_TOOLS.map { |t| t[:name] }
    assert_equal expected.sort, listed_names.sort

    body["tools"].each do |t|
      assert t["description"].present?, "tool #{t['name']} should include a description"
    end
  end

  test "well-known MCP manifest sends permissive CORS and short cache headers" do
    get "/.well-known/mcp.json"

    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_match(/public/, response.headers["Cache-Control"])
    assert_match(/max-age=\d+/, response.headers["Cache-Control"])
  end

  test "well-known MCP manifest is served on the mcp.smarts.md host too" do
    host! "mcp.smarts.md"
    get "/.well-known/mcp.json"
    assert_response :success
    assert_equal "smarts", JSON.parse(response.body)["name"]
  end

  test "public descriptions no longer advertise the removed governance timeline" do
    get "/.well-known/ai-plugin.json"
    assert_response :success
    refute_match(/governance/i, response.body)

    get "/api/openapi.json"
    assert_response :success
    refute_match(/governance/i, JSON.parse(response.body).dig("info", "description"))

    get "/chains/eth.md"
    assert_response :success
    assert_match "recent activity, and admin controls", response.body
  end

  test "Aave V3 market tool is advertised in discovery and the openapi spec" do
    get "/.well-known/ai-plugin.json"
    assert_match "Aave V3 lending markets", JSON.parse(response.body)["description_for_model"]

    get "/api/openapi.json"
    assert JSON.parse(response.body)["paths"].keys.any? { |path| path.include?("get_aave_v3_market") }

    assert_includes MarketingController::MCP_EXAMPLE_QUERIES.map { |q| q[:tool] }, "get_aave_v3_market"
  end

  test "DefiLlama dataset tools are advertised in discovery" do
    get "/.well-known/ai-plugin.json"
    assert_match "DefiLlama stablecoin supply, protocol TVL and yield pools", JSON.parse(response.body)["description_for_model"]

    examples = MarketingController::MCP_EXAMPLE_QUERIES.map { |q| q[:tool] }
    assert_includes examples, "get_stablecoin_supply"
    assert_includes examples, "get_yield_pools"
  end

  test "Uniswap V3 quote tools are advertised in discovery" do
    get "/.well-known/ai-plugin.json"
    assert_match "pool discovery and swap quotes", JSON.parse(response.body)["description_for_model"]
    assert_includes MarketingController::MCP_EXAMPLE_QUERIES.map { |q| q[:tool] }, "quote_uniswap_v3_swap"
  end
end
