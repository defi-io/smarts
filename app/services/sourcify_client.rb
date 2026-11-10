# Sourcify's verification API, used when the available Etherscan or Blockscout
# index is not complete enough for our contracts. Arc is the first: Sourcify and
# ArcScan (Etherscan V2) each verify a different subset of our contracts, so
# Chain#explorer_client wraps this client and Etherscan V2 in a
# FallbackExplorerClient, Sourcify first.
#
# Unlike the other two clients this is not an Etherscan-shaped API, so it does
# not go through `ExplorerClient#request`:
#
#   1. A contract is addressed by path — `v2/contract/<chainId>/<address>` —
#      not by `module`/`action` query params.
#   2. There is no `status`/`message` envelope. An unverified address returns
#      HTTP 404 with a well-formed body whose `match` is null, which is the
#      only unverified signal; there is no `"Contract source code not verified"`
#      sentinel to key off.
#   3. Response fields are opt-in via `?fields=`. Asking for everything on
#      every call would pull full sources for proxies we only need an
#      implementation address from, so the proxy probe and the source fetch
#      request different field sets.
#   4. `sources` already arrives as the `{path => {content}}` map that
#      `SourceCodeHelper#source_files` understands — no re-assembly needed,
#      unlike Blockscout's SourceCode + AdditionalSources split.
#   5. Proxies are resolved by Sourcify itself (`proxyResolution.isProxy` plus
#      `implementations[]`), so we trust it rather than re-deriving EIP-1967
#      slots.
class SourcifyClient < ExplorerClient
  EXPLORER_NAME = "Sourcify".freeze

  # Fields for the first call: enough to detect a proxy and to build the
  # contract record if it isn't one.
  CONTRACT_FIELDS = "abi,compilation,sources,proxyResolution".freeze

  # Sourcify's public server is shared infrastructure with no API key. Source
  # and ABI are persisted after the first fetch, so a conservative floor costs
  # nothing on the hot path and keeps us well clear of its limiter.
  self.throttle_interval = 0.5

  # Sourcify only serves verification data — no logs endpoint. Every chain we
  # register against it is Tier 1, so events go through RPC eth_getLogs.
  def logs_supported?
    false
  end

  def fetch_contract_info(address)
    source = fetch_source(address)
    impl_address = implementation_address_for(source)

    if impl_address
      impl_source = fetch_source(impl_address)

      contract_attributes(
        name: contract_name_for(impl_source),
        compiler_version: compiler_version_for(impl_source),
        source_code: source_code_for(impl_source),
        abi: abi_for(impl_source, impl_address),
        implementation_address: impl_address.downcase
      )
    else
      contract_attributes(
        name: contract_name_for(source),
        compiler_version: compiler_version_for(source),
        source_code: source_code_for(source),
        abi: abi_for(source, address)
      )
    end
  end

  private

  def fetch_source(address)
    @address = address
    body = get_body(fields: CONTRACT_FIELDS)

    # `match` is null both for "never verified" and for an address with no
    # code at all; Sourcify does not distinguish them and neither do we.
    if body["match"].blank?
      raise NotVerifiedError, "Contract #{address} is not verified on #{@chain.name}"
    end

    body
  end

  def abi_for(source, address)
    abi = source["abi"]
    raise NotVerifiedError, "Contract #{address} has no ABI on Sourcify for #{@chain.name}" if abi.blank?

    abi
  end

  def contract_name_for(source)
    source.dig("compilation", "name")
  end

  # Sourcify reports a bare semver ("0.8.24+commit.e11b9ed9") where Etherscan
  # and Blockscout both prefix a "v". Normalise so the compiler version reads
  # the same across chains wherever it's displayed.
  def compiler_version_for(source)
    version = source.dig("compilation", "compilerVersion")
    return version if version.blank? || version.start_with?("v")

    "v#{version}"
  end

  # Already the `{path => {content}}` shape used elsewhere; serialise it so it
  # round-trips through the `source_code` text column like the other clients'
  # standard-json payloads. A single-file verification stays a JSON map too,
  # which `source_files` handles.
  def source_code_for(source)
    files = source["sources"]
    return nil if files.blank?

    files.to_json
  end

  def implementation_address_for(source)
    resolution = source["proxyResolution"]
    return nil unless resolution.is_a?(Hash)
    return nil unless ActiveModel::Type::Boolean.new.cast(resolution["isProxy"])

    Array(resolution["implementations"]).first&.dig("address").presence
  end

  def request_path(_params)
    "v2/contract/#{@chain.chain_id}/#{@address}"
  end
end
