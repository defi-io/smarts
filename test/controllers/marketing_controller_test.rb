require "test_helper"

class MarketingControllerTest < ActionDispatch::IntegrationTest
  test "home renders successfully with the hero" do
    get root_path
    assert_response :success
    assert_match "smarts.md", response.body
    assert_match "Live docs for every smart contract.", response.body
  end

  test "home surfaces MCP entry link to mcp.smarts.md" do
    get root_path
    assert_response :success
    assert_match %r{<a href="https://mcp\.smarts\.md/"[^>]*>connect your AI agent</a>}, response.body
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

    # Spot-check a few featured items render as clickable links. Items with
    # a slug link via `/{slug}`, items without link via `/{chain}/{address}`.
    MarketingController::FEATURED.sample(3).each do |item|
      slug = ContractSlugs.for(item[:chain], item[:address])
      expected_href = slug ? "/#{slug}" : "/#{item[:chain]}/#{item[:address]}"
      assert_match expected_href, response.body,
                   "expected link to #{expected_href} on home page"
    end
  end

  test "home still redirects on q= input with chain/address pattern" do
    get root_path, params: { q: "eth/0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" }
    assert_redirected_to "/eth/0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  end

  # Structural guards on the FEATURED constant — catches typos, wrong chain
  # slugs, malformed addresses before they hit production.

  test "every FEATURED entry has a supported chain slug" do
    supported = MarketingController::CHAIN_LABELS.keys
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

  test "every FEATURED chain has a display label in CHAIN_LABELS" do
    featured_chains = MarketingController::FEATURED.map { |i| i[:chain] }.uniq
    missing = featured_chains - MarketingController::CHAIN_LABELS.keys
    assert_empty missing, "chains in FEATURED but not in CHAIN_LABELS: #{missing.inspect}"
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
    assert_match "https://smarts.md/mcp/sse", response.body
    assert_match "Quick install", response.body
    assert_match "claude mcp add", response.body
    assert_match "Ask your AI", response.body
    assert_match "Tools", response.body
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

  # Production-critical guard: the new host-constrained root route MUST NOT
  # shadow fast-mcp middleware at /mcp/*. If it ever does, AI clients hitting
  # mcp.smarts.md/mcp/sse would get the marketing HTML page instead of an
  # MCP SSE stream, and nobody would know until agents silently fail to
  # connect.
  test "MCP middleware still serves /mcp on the mcp.smarts.md host (not shadowed by marketing)" do
    host! "mcp.smarts.md"
    get "/mcp"

    refute_match "Point your AI at smarts.md", response.body,
                 "the MCP endpoint path must not render the marketing docs page"
    assert_match(/jsonrpc/, response.body,
                 "fast-mcp middleware should respond with JSON-RPC, proving it's still in front of the route")
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

  test "well-known MCP manifest advertises the SSE transport with explicit endpoints" do
    get "/.well-known/mcp.json"
    body = JSON.parse(response.body)

    sse = body["transports"].find { |t| t["type"] == "sse" }
    assert sse, "expected a transport of type sse"
    assert_equal "https://smarts.md/mcp/sse",      sse["endpoint"]
    assert_equal "https://smarts.md/mcp/messages", sse["messages"]
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
end
