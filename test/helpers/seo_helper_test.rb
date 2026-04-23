require "test_helper"
require "ostruct"

class SeoHelperTest < ActionView::TestCase
  test "page_title falls back to default when nothing is set" do
    assert_equal SeoHelper::DEFAULT_TITLE, page_title
  end

  # Guards against shortening the title back into "too short" SEO territory.
  # The opengraph.xyz audit flagged anything under 50 chars as suboptimal
  # (truncated in SERP, weak snippet signal); over 60 gets cut off at display.
  # Locks the range without ossifying the exact wording.
  test "DEFAULT_TITLE stays within the 50-60 char SEO-optimal range" do
    len = SeoHelper::DEFAULT_TITLE.length
    assert (50..60).cover?(len),
      "DEFAULT_TITLE is #{len} chars (#{SeoHelper::DEFAULT_TITLE.inspect}); optimal is 50–60"
  end

  test "page_title appends site suffix to a custom title" do
    seo_meta title: "Foo"
    assert_equal "Foo | smarts.md", page_title
  end

  test "page_description falls back to default when nothing is set" do
    assert_equal SeoHelper::DEFAULT_DESC, page_description
  end

  test "page_description returns custom value when set" do
    seo_meta description: "Custom description"
    assert_equal "Custom description", page_description
  end

  test "page_og_type defaults to website" do
    assert_equal "website", page_og_type
  end

  test "render_social_meta emits required og and twitter tags" do
    seo_meta title: "Foo", description: "Bar", canonical: "https://smarts.md/foo"

    html = render_social_meta
    assert_match(/<meta name="description" content="Bar">/, html)
    assert_match(/<meta property="og:site_name" content="Smarts">/, html)
    assert_match(/<meta property="og:title" content="Foo \| smarts.md">/, html)
    assert_match(/<meta property="og:description" content="Bar">/, html)
    assert_match(/<meta property="og:url" content="https:\/\/smarts.md\/foo">/, html)
    assert_match(/<meta property="og:type" content="website">/, html)
    assert_match(/<meta property="og:image" content="https:\/\/smarts.md\/og-default.png">/, html)
    assert_match(/<meta name="twitter:card" content="summary_large_image">/, html)
    assert_match(/<meta name="twitter:title" content="Foo \| smarts.md">/, html)
  end

  test "contract_json_ld emits valid schema.org WebPage with SoftwareApplication entity" do
    contract = OpenStruct.new(
      name: "USD Coin",
      address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    )
    chain = OpenStruct.new(name: "Ethereum", slug: "eth")
    classification = OpenStruct.new(display_name: "ERC-20 Token", description: "A fungible token.")
    seo_meta title: "USD Coin on Ethereum", description: "desc", canonical: "https://smarts.md/usdc-eth"

    html = contract_json_ld(contract: contract, chain: chain, classification: classification)

    # The helper returns a <script> tag with embedded JSON.
    assert_match(%r{<script type="application/ld\+json">}, html)

    # Strip the wrapper and verify the JSON parses and has the right shape.
    json = html.match(%r{<script[^>]*>(.+)</script>}m)[1]
    data = JSON.parse(json)

    assert_equal "https://schema.org", data["@context"]
    assert_equal "WebPage", data["@type"]
    assert_equal "https://smarts.md/usdc-eth", data["url"]
    assert_equal "USD Coin on Ethereum | smarts.md", data["name"]
    assert_equal "Smarts", data["isPartOf"]["name"]

    app = data["about"]
    assert_equal "SoftwareApplication", app["@type"]
    assert_equal "USD Coin", app["name"]
    assert_equal "SmartContract", app["applicationCategory"]
    assert_equal "Ethereum", app["operatingSystem"]
    assert_equal "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", app["identifier"]
    assert_equal "ERC-20 Token", app["additionalType"]
    assert_equal "A fungible token.", app["description"]
  end

  test "contract_json_ld omits classification fields when classification is nil" do
    contract = OpenStruct.new(name: "Thing", address: "0xabc")
    chain = OpenStruct.new(name: "Ethereum")
    seo_meta canonical: "https://smarts.md/eth/0xabc"

    html = contract_json_ld(contract: contract, chain: chain, classification: nil)
    json = html.match(%r{<script[^>]*>(.+)</script>}m)[1]
    data = JSON.parse(json)

    refute data["about"].key?("additionalType")
    refute data["about"].key?("description")
  end

  test "contract_json_ld escapes dangerous sequences that could break out of the script tag" do
    contract = OpenStruct.new(name: "Malicious </script><script>alert(1)</script>", address: "0xabc")
    chain = OpenStruct.new(name: "Ethereum")
    seo_meta canonical: "https://smarts.md/eth/0xabc"

    html = contract_json_ld(contract: contract, chain: chain, classification: nil)
    # Only one opening script tag should be present — json_escape converts `</` into `<\/`.
    assert_equal 1, html.scan("<script").size
  end

  test "contract_json_ld includes softwareVersion and license when contract has them" do
    contract = OpenStruct.new(
      name: "USD Coin",
      address: "0xa0b8",
      compiler_version: "v0.8.20+commit.a1b79de6",
      license: "MIT"
    )
    chain = OpenStruct.new(name: "Ethereum")
    seo_meta canonical: "https://smarts.md/usdc-eth"

    html = contract_json_ld(contract: contract, chain: chain, classification: nil)
    data = JSON.parse(html.match(%r{<script[^>]*>(.+)</script>}m)[1])

    assert_equal "v0.8.20+commit.a1b79de6", data["about"]["softwareVersion"]
    assert_equal "MIT", data["about"]["license"]
  end

  test "contract_json_ld omits softwareVersion and license when blank" do
    contract = OpenStruct.new(name: "Thing", address: "0xabc", compiler_version: nil, license: nil)
    chain = OpenStruct.new(name: "Ethereum")
    seo_meta canonical: "https://smarts.md/eth/0xabc"

    html = contract_json_ld(contract: contract, chain: chain, classification: nil)
    data = JSON.parse(html.match(%r{<script[^>]*>(.+)</script>}m)[1])

    refute data["about"].key?("softwareVersion")
    refute data["about"].key?("license")
  end

  test "breadcrumb_json_ld emits ordered BreadcrumbList with positions" do
    html = breadcrumb_json_ld([
      { name: "Smarts", url: "https://smarts.md/" },
      { name: "UNI on Ethereum", url: "https://smarts.md/uni-eth" }
    ])
    data = JSON.parse(html.match(%r{<script[^>]*>(.+)</script>}m)[1])

    assert_equal "BreadcrumbList", data["@type"]
    assert_equal 2, data["itemListElement"].size
    assert_equal 1, data["itemListElement"][0]["position"]
    assert_equal "Smarts", data["itemListElement"][0]["name"]
    assert_equal "https://smarts.md/", data["itemListElement"][0]["item"]
    assert_equal 2, data["itemListElement"][1]["position"]
    assert_equal "UNI on Ethereum", data["itemListElement"][1]["name"]
  end

  test "home_json_ld emits a WebSite with a SearchAction matching the homepage search form" do
    html = home_json_ld
    data = JSON.parse(html.match(%r{<script[^>]*>(.+)</script>}m)[1])

    assert_equal "WebSite", data["@type"]
    assert_equal "Smarts", data["name"]
    assert_equal "https://smarts.md/", data["url"]

    action = data["potentialAction"]
    assert_equal "SearchAction", action["@type"]
    assert_equal "https://smarts.md/?q={search_term_string}", action["target"]["urlTemplate"]
    assert_equal "required name=search_term_string", action["query-input"]
  end
end
