# frozen_string_literal: true

# Base class for all MCP tools, on top of the official `mcp` gem
# (modelcontextprotocol/ruby-sdk).
#
# Subclasses define their business logic in `self.payload(**args)`,
# returning a plain Ruby Hash. The base class's `self.call` wraps that
# hash in the `MCP::Tool::Response` shape required by the SDK,
# JSON-encoding the payload as a single text content block — that's how
# MCP clients (Claude, Cursor, …) feed structured tool output back to
# the LLM.
#
# Splitting `payload` from `call` keeps the SDK plumbing in one place
# and lets tests assert against the underlying Hash directly without
# unwrapping protocol envelopes.
class ApplicationTool < MCP::Tool
  class << self
    # MCP SDK entry point. Subclasses don't override this — they
    # implement `payload` instead. We accept `server_context:` to match
    # the SDK contract but currently ignore it (no per-request state).
    def call(server_context: nil, **args)
      text_response(payload(**args))
    end

    # Subclasses implement this and return a plain Hash.
    def payload(**)
      raise NotImplementedError, "#{name} must implement self.payload(**args)"
    end

    # Wraps a plain Hash (or already-built Response) into the
    # MCP::Tool::Response shape required by the SDK.
    def text_response(hash)
      return hash if hash.is_a?(MCP::Tool::Response)

      MCP::Tool::Response.new([ { type: "text", text: hash.to_json } ], error: error_payload?(hash))
    end

    # Every tool reports failure as a Hash with a non-blank :error. MCP
    # clients get isError: true and REST callers a 422 from that one rule.
    def error_payload?(hash)
      hash.is_a?(Hash) && hash[:error].present?
    end

    # Resolves a tool's contract input (either a slug OR chain+address) to a
    # [chain_record, contract] pair. Returns an error hash on any failure —
    # callers should short-circuit when the result is a Hash.
    #
    # Slug wins when both are supplied (friendlier than erroring on conflict).
    #
    # `require_full: true` rejects docs_only chains with a friendly error so
    # live-data tools (RPC-backed) fail fast instead of timing out.
    def resolve_contract(chain: nil, address: nil, slug: nil, require_full: false)
      if slug.present?
        lookup = ContractSlugResolver.resolve(slug)
        return { error: "unknown slug: #{slug}" } unless lookup

        chain_slug, address = lookup
      else
        return { error: "either `slug` or both `chain` + `address` required" } if chain.blank? || address.blank?

        chain_slug = chain
      end

      chain_record = Chain.find_by(slug: chain_slug)
      return { error: "unknown chain: #{chain_slug}" } unless chain_record

      tier_error = check_full_tier(chain_record) if require_full
      return tier_error if tier_error

      normalized_address = address.to_s.downcase
      contract = Contract.find_by(chain: chain_record, address: normalized_address)
      unless contract
        return { error: "contract not indexed — visit https://smarts.md/#{chain_slug}/#{normalized_address} first" }
      end

      [ chain_record, contract ]
    end

    # Token argument → lowercased address. Accepts a 0x address or a curated
    # slug on the same chain (e.g. "usdc-base"). Returns [address, nil] or
    # [nil, error_hash].
    def resolve_token(chain_slug, value)
      text = value.to_s.strip
      return [ text.downcase, nil ] if text.match?(/\A0x[0-9a-fA-F]{40}\z/)

      lookup = ContractSlugResolver.resolve(text.downcase)
      return [ nil, { error: "token must be a 0x address or a curated slug: #{value.inspect}" } ] unless lookup
      return [ nil, { error: "#{text} is on #{lookup[0]}, not #{chain_slug}" } ] unless lookup[0] == chain_slug

      [ lookup[1].downcase, nil ]
    end

    # Returns an error hash if the chain is docs_only, nil otherwise.
    # Used by tools that need live RPC data (state, events, balances).
    def check_full_tier(chain_record)
      return nil if chain_record.full?

      {
        error: "chain '#{chain_record.slug}' is docs-only — Smarts indexes source code and ABI on this chain, but live on-chain data (state, events, balances) is not available. Use get_contract_info or get_contract_source instead."
      }
    end

    # Returns the publisher User resolved from the current MCP request's
    # `Authorization: Bearer <token>` header (set by `McpBearerAuth` on
    # `Current.mcp_user`), or the standard error Hash if no valid token was
    # presented. Callers short-circuit when the result is a Hash, mirroring
    # `resolve_contract`.
    def current_publisher
      Current.mcp_user || { error: "Authorization: Bearer <publish_token> header is missing or invalid" }
    end
  end
end
