# Blockscout's Etherscan-compatible `/api` shim. Robinhood Chain uses it
# while Etherscan V2's new index has incomplete proxy coverage. Same endpoints
# (`contract/getsourcecode`, `contract/getabi`), three response differences:
#
#   1. Unverified addresses come back `status: "1"` with a result row holding
#      only `Address` — no `ABI: "Contract source code not verified"` sentinel.
#   2. Proxies are flagged `IsProxy` + `ImplementationAddress`, not
#      `Proxy` + `Implementation`. `IsProxy` is a JSON boolean on some
#      instances and the string "false" on others.
#   3. `getsourcecode` already carries the full ABI, so no second `getabi`
#      round-trip is needed.
#   4. Multi-file verifications arrive split: the primary file in `SourceCode`,
#      the rest in `AdditionalSources`.
class BlockscoutClient < ExplorerClient
  EXPLORER_NAME = "Blockscout".freeze

  # Public Blockscout instances rate-limit anonymous traffic hard (a ~45-call
  # burst against robinhoodchain.blockscout.com returns HTTP 429 with
  # `status: "0"`), and we have no API key. Source/ABI data is persisted after
  # the first fetch, so a slow floor costs nothing on the hot path.
  self.throttle_interval = 0.5

  # Blockscout exposes `logs/getLogs`, but with per-instance pagination
  # semantics and a narrow block window. Every Blockscout chain we register is
  # Tier 1 (has an RPC URL), so event fetching goes through RPC instead.
  def logs_supported?
    false
  end

  def fetch_contract_info(address)
    source = fetch_source_code(address)
    impl_address = implementation_address_for(source)

    if impl_address
      impl_source = fetch_source_code(impl_address)

      contract_attributes(
        name: impl_source["ContractName"],
        compiler_version: impl_source["CompilerVersion"],
        source_code: source_code_for(impl_source),
        abi: parse_abi(impl_source),
        implementation_address: impl_address.downcase
      )
    else
      contract_attributes(
        name: source["ContractName"],
        compiler_version: source["CompilerVersion"],
        source_code: source_code_for(source),
        abi: parse_abi(source)
      )
    end
  end

  private

  def fetch_source_code(address)
    data = Array(request(module: "contract", action: "getsourcecode", address: address)).first || {}

    if data["ABI"].blank? || data["ABI"] == "Contract source code not verified"
      raise NotVerifiedError, "Contract #{address} is not verified on #{@chain.name}"
    end

    data
  end

  # Blockscout inlines the ABI as a JSON string; older instances hand back an
  # already-parsed array.
  def parse_abi(source)
    abi = source["ABI"]
    abi.is_a?(String) ? JSON.parse(abi) : abi
  rescue JSON::ParserError => e
    raise Error, "Blockscout returned an unparseable ABI: #{e.message}"
  end

  # Etherscan ships a multi-file verification as one standard-json blob;
  # Blockscout splits it into `SourceCode` (primary file) + `AdditionalSources`.
  # Re-assemble into the `{path => {content}}` map `SourceCodeHelper#source_files`
  # already understands, so the Source tab and get_contract_source see every
  # file. Single-file contracts stay a plain Solidity string.
  def source_code_for(source)
    extra = Array(source["AdditionalSources"])
    return source["SourceCode"] if extra.empty?

    files = { source["FileName"].presence || "contract.sol" => { "content" => source["SourceCode"].to_s } }
    extra.each_with_index do |file, index|
      path = file["Filename"].presence || file["FileName"].presence || "additional_#{index + 1}.sol"
      files[path] = { "content" => file["SourceCode"].to_s }
    end
    files.to_json
  end

  def implementation_address_for(source)
    return nil unless ActiveModel::Type::Boolean.new.cast(source["IsProxy"])

    source["ImplementationAddress"].presence || Array(source["ImplementationAddresses"]).first.presence
  end
end
