# frozen_string_literal: true

class GetContractSourceTool < ApplicationTool
  tool_name "get_contract_source"
  description "Fetch the verified Solidity source for an indexed contract. Three modes by argument: no `file`/`search` returns a file index; `file:` returns one file's content; `search:` greps across all files (case-insensitive substring). Accepts a curated slug or chain+address."

  MAX_FILE_CHARS    = 100_000
  MAX_SEARCH_HITS   = 50
  SNIPPET_MAX_CHARS = 200

  input_schema(
    properties: {
      slug:    { type: "string", description: "Curated slug like 'uni-eth'. Alternative to chain+address." },
      chain:   { type: "string", description: "Chain slug: eth, base, arbitrum, optimism, polygon. Required unless `slug` given." },
      address: { type: "string", description: "0x-prefixed EVM contract address. Required unless `slug` given." },
      file:    { type: "string", description: "Optional. Path or basename of a single file to fetch (e.g. 'AaveToken.sol' or 'contracts/Token.sol'). Mutually exclusive with `search`." },
      search:  { type: "string", description: "Optional. Case-insensitive substring grep across every file. Returns up to 50 path/line/snippet hits. Mutually exclusive with `file`." }
    }
  )

  class << self
    def payload(chain: nil, address: nil, slug: nil, file: nil, search: nil)
      resolved = resolve_contract(chain: chain, address: address, slug: slug)
      return resolved if resolved.is_a?(Hash)

      _chain_record, contract = resolved
      return { error: "contract source not indexed" } if contract.source_code.blank?
      return { error: "use either `file` or `search`, not both" } if file.present? && search.present?

      files = ApplicationController.helpers.source_files(contract.source_code)

      if search.present?
        search_response(files, search)
      elsif file.present?
        file_response(files, file)
      else
        index_response(files, contract)
      end
    end

    private

    def index_response(files, contract)
      {
        chain: contract.chain.slug,
        address: contract.address,
        slug: ContractSlugs.for(contract.chain.slug, contract.address),
        compiler_version: contract.compiler_version,
        total_files: files.size,
        total_bytes: files.sum { |f| f[:content].bytesize },
        files: files.map { |f| { path: f[:path], bytes: f[:content].bytesize } }
      }
    end

    def file_response(files, requested)
      match = match_file(files, requested)
      return match if match.is_a?(Hash) && match[:error]

      content   = match[:content]
      truncated = content.length > MAX_FILE_CHARS

      {
        path: match[:path],
        content: truncated ? content[0, MAX_FILE_CHARS] : content,
        bytes: content.bytesize,
        truncated: truncated
      }
    end

    def search_response(files, query)
      target = query.downcase
      hits = []
      truncated = false

      files.each do |f|
        f[:content].each_line.with_index(1) do |line, lineno|
          next unless line.downcase.include?(target)

          snippet = line.chomp.strip
          snippet = snippet[0, SNIPPET_MAX_CHARS] + "…" if snippet.length > SNIPPET_MAX_CHARS
          hits << { path: f[:path], line: lineno, snippet: snippet }

          if hits.size >= MAX_SEARCH_HITS
            truncated = true
            break
          end
        end
        break if truncated
      end

      {
        query: query,
        hit_count: hits.size,
        truncated: truncated,
        hits: hits
      }
    end

    def match_file(files, requested)
      exact = files.find { |f| f[:path] == requested }
      return exact if exact

      basename_matches = files.select { |f| File.basename(f[:path]) == requested }
      case basename_matches.size
      when 1 then basename_matches.first
      when 0 then { error: "file not found: #{requested}", available: files.map { |f| f[:path] } }
      else        { error: "ambiguous file name: #{requested}", candidates: basename_matches.map { |f| f[:path] } }
      end
    end
  end
end
