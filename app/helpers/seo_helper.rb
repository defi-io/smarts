module SeoHelper
  SITE_NAME        = "Smarts".freeze
  SITE_URL         = "https://smarts.md".freeze
  DEFAULT_TITLE    = "Smarts — Live docs for every smart contract".freeze
  DEFAULT_DESC     = "Live on-chain docs for every verified smart contract on Ethereum, Base, Arbitrum, Optimism, and Polygon. Point your AI agent at one URL.".freeze
  DEFAULT_OG_IMAGE = "#{SITE_URL}/icon.png".freeze

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
      tag.meta(name: "twitter:card",        content: "summary"),
      tag.meta(name: "twitter:title",       content: page_title),
      tag.meta(name: "twitter:description", content: page_description),
      tag.meta(name: "twitter:image",       content: DEFAULT_OG_IMAGE)
    ], "\n  ")
  end

  # JSON-LD for a contract page. Uses schema.org WebPage wrapping a
  # SoftwareApplication entity that describes the contract itself.
  def contract_json_ld(contract:, chain:, classification: nil)
    app = {
      "@type"               => "SoftwareApplication",
      "name"                => contract.name.presence || "Unknown Contract",
      "applicationCategory" => "SmartContract",
      "operatingSystem"     => chain.name,
      "identifier"          => contract.address
    }
    app["additionalType"]  = classification.display_name if classification&.display_name.present?
    app["description"]     = classification.description  if classification&.description.present?
    app["softwareVersion"] = contract.compiler_version   if contract.compiler_version.present?
    app["license"]         = contract.license            if contract.license.present?

    data = {
      "@context"    => "https://schema.org",
      "@type"       => "WebPage",
      "@id"         => page_canonical_url,
      "url"         => page_canonical_url,
      "name"        => page_title,
      "description" => page_description,
      "isPartOf"    => { "@type" => "WebSite", "name" => SITE_NAME, "url" => SITE_URL },
      "about"       => app
    }

    render_json_ld(data)
  end

  # BreadcrumbList schema — Google renders this as the breadcrumb trail in
  # SERP results. `items` is an ordered array of `{name:, url:}`.
  def breadcrumb_json_ld(items)
    data = {
      "@context"        => "https://schema.org",
      "@type"           => "BreadcrumbList",
      "itemListElement" => items.each_with_index.map do |item, i|
        { "@type" => "ListItem", "position" => i + 1, "name" => item[:name], "item" => item[:url] }
      end
    }
    render_json_ld(data)
  end

  # WebSite schema with SearchAction — emitted on the homepage. Makes us
  # eligible for Google's sitelinks searchbox on brand queries.
  def home_json_ld
    data = {
      "@context" => "https://schema.org",
      "@type"    => "WebSite",
      "name"     => SITE_NAME,
      "url"      => "#{SITE_URL}/",
      "potentialAction" => {
        "@type"       => "SearchAction",
        "target"      => { "@type" => "EntryPoint", "urlTemplate" => "#{SITE_URL}/?q={search_term_string}" },
        "query-input" => "required name=search_term_string"
      }
    }
    render_json_ld(data)
  end

  private

  def render_json_ld(data)
    tag.script(ERB::Util.json_escape(data.to_json).html_safe, type: "application/ld+json")
  end
end
