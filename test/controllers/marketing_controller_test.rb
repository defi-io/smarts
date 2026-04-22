require "test_helper"

class MarketingControllerTest < ActionDispatch::IntegrationTest
  test "home renders successfully with the hero" do
    get root_path
    assert_response :success
    assert_match "smarts.md", response.body
    assert_match "Live docs for every smart contract.", response.body
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

    # Spot-check a few featured items render as clickable links to the right URL
    MarketingController::FEATURED.sample(3).each do |item|
      expected_href = "/#{item[:chain]}/#{item[:address]}"
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
end
