module SeoHelper
  SITE_NAME        = "Smarts".freeze
  SITE_URL         = "https://smarts.md".freeze
  DEFAULT_TITLE    = "Smarts — Live on-chain docs for every smart contract".freeze
  DEFAULT_DESC     = "Live on-chain docs for every verified smart contract on Ethereum, Base, Arbitrum, Optimism, BNB Smart Chain, Polygon, Robinhood Chain, and Arc. Point your AI agent at one URL.".freeze
  DEFAULT_OG_IMAGE = "#{SITE_URL}/og-default.png".freeze

  # Set per-page SEO fields from a view. Any omitted field falls back to site
  # defaults when rendered.
  def seo_meta(title: nil, description: nil, canonical: nil, og_type: "website")
    content_for :page_title,       title       if title
    content_for :page_description, description if description
    content_for :canonical_url,    canonical   if canonical
    content_for :og_type,          og_type     if og_type
  end

  def page_title
    custom = content_for(:page_title)
    custom.present? ? "#{custom} | smarts.md" : DEFAULT_TITLE
  end

  def page_description
    content_for(:page_description).presence || DEFAULT_DESC
  end

  def page_canonical_url
    content_for(:canonical_url).presence || request.original_url
  end

  def page_og_type
    content_for(:og_type).presence || "website"
  end

  # Render site-wide + per-page meta tags. Called once from the layout head.
  def render_social_meta
    safe_join([
      tag.meta(name: "description", content: page_description),
      tag.meta(property: "og:site_name",  content: SITE_NAME),
      tag.meta(property: "og:title",      content: page_title),
      tag.meta(property: "og:description", content: page_description),
      tag.meta(property: "og:url",        content: page_canonical_url),
      tag.meta(property: "og:type",       content: page_og_type),
      tag.meta(property: "og:image",      content: DEFAULT_OG_IMAGE),
      tag.meta(name: "twitter:card",        content: "summary_large_image"),
      tag.meta(name: "twitter:title",       content: page_title),
      tag.meta(name: "twitter:description", content: page_description),
      tag.meta(name: "twitter:image",       content: DEFAULT_OG_IMAGE)
    ], "\n  ")
  end

  private

  def render_json_ld(data)
    tag.script(ERB::Util.json_escape(data.to_json).html_safe, type: "application/ld+json")
  end
end
