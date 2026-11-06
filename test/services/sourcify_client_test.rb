require "test_helper"

class SourcifyClientTest < ActiveSupport::TestCase
  ADDRESS = "0xbef5f6d51cb62b58e6a8f77868681825c6fe21c1".freeze
  IMPL    = "0x43506849d7c04f9138d1a2050bbf3a0c054402dd".freeze

  setup do
    @chain = chains(:arc)
    @client = SourcifyClient.new(@chain)
  end

  test "addresses the contract by path under the seeded server URL" do
    stub = stub_contract(ADDRESS, body)

    @client.fetch_contract_info(ADDRESS)

    assert_requested stub, times: 1
  end

  test "fetch_contract_info maps compilation, sources and abi" do
    stub_contract(ADDRESS, body)

    info = @client.fetch_contract_info(ADDRESS)

    assert_equal "EURC", info[:name]
    assert_equal "totalSupply", info[:abi].first["name"]
    assert_nil info[:implementation_address]
    assert_not_nil info[:verified_at]
  end

  # Sourcify reports a bare semver; Etherscan and Blockscout both prefix "v".
  test "normalises the compiler version to the v-prefixed form" do
    stub_contract(ADDRESS, body)

    assert_equal "v0.8.24+commit.e11b9ed9", @client.fetch_contract_info(ADDRESS)[:compiler_version]
  end

  test "leaves an already-prefixed compiler version alone" do
    stub_contract(ADDRESS, body(compiler_version: "v0.8.24+commit.e11b9ed9"))

    assert_equal "v0.8.24+commit.e11b9ed9", @client.fetch_contract_info(ADDRESS)[:compiler_version]
  end

  # `sources` already arrives as the {path => {content}} map the Source tab
  # understands, so it is stored verbatim rather than re-assembled.
  test "stores the sources map as JSON without re-assembly" do
    stub_contract(ADDRESS, body)

    files = JSON.parse(@client.fetch_contract_info(ADDRESS)[:source_code])

    assert_equal [ "EURC.sol", "lib/ERC20.sol" ], files.keys.sort
    assert_equal "contract EURC {}", files.dig("EURC.sol", "content")
  end

  test "extracts NatSpec from the assembled sources" do
    sources = {
      "EURC.sol" => { "content" => <<~SOL }
        contract EURC {
          /// @notice Total tokens in circulation.
          function totalSupply() external view returns (uint256) {}
        }
      SOL
    }
    stub_contract(ADDRESS, body(sources: sources))

    info = @client.fetch_contract_info(ADDRESS)

    assert_equal "Total tokens in circulation.", info[:natspec].dig("functions", "totalSupply", "notice")
  end

  # Sourcify resolves proxies itself; we follow its answer instead of
  # re-deriving EIP-1967 slots.
  test "follows proxyResolution to the implementation" do
    stub_contract(ADDRESS, body(proxy: {
      "isProxy" => true,
      "proxyType" => "EIP1967Proxy",
      "implementations" => [ { "address" => IMPL, "name" => "EURCV2" } ]
    }))
    stub_contract(IMPL, body(name: "EURCV2"))

    info = @client.fetch_contract_info(ADDRESS)

    assert_equal "EURCV2", info[:name]
    assert_equal IMPL, info[:implementation_address]
  end

  test "ignores proxyResolution when isProxy is false" do
    stub_contract(ADDRESS, body(proxy: { "isProxy" => false, "implementations" => [] }))

    assert_nil @client.fetch_contract_info(ADDRESS)[:implementation_address]
  end

  # An unverified address is a 404 whose body parses fine and carries a null
  # `match` — there is no Etherscan-style sentinel string to key off.
  test "raises NotVerifiedError on a null match" do
    stub_request(:get, %r{sourcify\.dev/server/v2/contract/5042/#{ADDRESS}}).to_return(
      status: 404,
      body: { match: nil, creationMatch: nil, runtimeMatch: nil, chainId: "5042", address: ADDRESS }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    assert_raises(SourcifyClient::NotVerifiedError) { @client.fetch_contract_info(ADDRESS) }
  end

  test "raises NotVerifiedError when a matched contract carries no ABI" do
    stub_contract(ADDRESS, body(abi: nil))

    assert_raises(SourcifyClient::NotVerifiedError) { @client.fetch_contract_info(ADDRESS) }
  end

  test "surfaces a non-JSON body as ExplorerClient::Error" do
    stub_request(:get, %r{sourcify\.dev/server/v2/contract/5042/#{ADDRESS}}).to_return(
      status: 500, body: "<html>Cannot GET</html>", headers: { "Content-Type" => "text/html" }
    )

    error = assert_raises(ExplorerClient::Error) { @client.fetch_contract_info(ADDRESS) }
    assert_match(/non-JSON/, error.message)
  end

  # Sourcify serves verification data only; events must go through RPC.
  test "does not support logs" do
    assert_not @client.logs_supported?
  end

  private

  def stub_contract(address, payload)
    stub_request(:get, "https://sourcify.dev/server/v2/contract/5042/#{address}")
      .with(query: { fields: SourcifyClient::CONTRACT_FIELDS })
      .to_return(
        status: 200,
        body: payload.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def body(name: "EURC", compiler_version: "0.8.24+commit.e11b9ed9", abi: :default, sources: :default, proxy: nil)
    {
      "match" => "match",
      "chainId" => "5042",
      "address" => ADDRESS,
      "abi" => abi == :default ? [ { "type" => "function", "name" => "totalSupply" } ] : abi,
      "compilation" => { "name" => name, "compilerVersion" => compiler_version },
      "sources" => sources == :default ? default_sources : sources,
      "proxyResolution" => proxy || { "isProxy" => false, "proxyType" => nil, "implementations" => [] }
    }
  end

  def default_sources
    {
      "EURC.sol" => { "content" => "contract EURC {}" },
      "lib/ERC20.sol" => { "content" => "contract ERC20 {}" }
    }
  end
end
