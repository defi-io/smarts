require "test_helper"

class ContractsControllerTest < ActionDispatch::IntegrationTest
  test "show renders existing contract" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    assert_select "h1", "Uni"
  end

  test "show via friendly slug resolves to the contract" do
    contract = contracts(:uni_token)
    contract.update!(address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984") # real UNI, which maps to uni-eth
    get "/uni-eth"
    assert_response :success
    assert_select "h1", "Uni"
  end

  test "show via hex URL 301s to slug when one exists" do
    uni_addr = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
    Contract.find_or_create_by!(chain: chains(:ethereum), address: uni_addr) do |c|
      c.name = "Uniswap"
      c.abi = []
    end

    get contract_path(chain: "eth", address: uni_addr)
    assert_redirected_to "/uni-eth"
    assert_equal 301, response.status
  end

  test "unknown slug with chain suffix returns 404" do
    get "/nonexistent-eth"
    assert_response :not_found
  end

  test "slug-eligible page emits canonical link tag" do
    contract = contracts(:uni_token)
    contract.update!(address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    get "/uni-eth"
    assert_response :success
    assert_match %r{<link rel="canonical" href=".*/uni-eth">}, response.body
  end

  test "non-slug contract page does NOT emit canonical link tag" do
    contract = contracts(:uni_token)
    # fixture address (0x1111...) is not in the slug map
    get contract_path(chain: "eth", address: contract.address)
    assert_response :success
    refute_match %r{rel="canonical"}, response.body
  end

  # ---------- SEO meta tags + JSON-LD ----------

  test "contract page sets OG title with chain and contract name" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    assert_match %r{<meta property="og:title" content="Uni on Ethereum — live on-chain contract docs \| smarts.md">}, response.body
    assert_match %r{<meta property="og:description"[^>]+Uni}, response.body
    assert_match %r{<meta property="og:type" content="website">}, response.body
    assert_match %r{<meta name="twitter:card" content="summary_large_image">}, response.body
  end

  test "contract page emits JSON-LD WebPage + SoftwareApplication block" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    data = response.body.scan(%r{<script type="application/ld\+json">(.+?)</script>}m)
                        .map { |m| JSON.parse(m[0]) }
                        .find { |j| j["@type"] == "WebPage" }
    assert data, "expected a WebPage JSON-LD on the contract page"
    assert_equal "SoftwareApplication", data["about"]["@type"]
    assert_equal "SmartContract", data["about"]["applicationCategory"]
    assert_equal "Ethereum", data["about"]["operatingSystem"]
    assert_equal contract.address, data["about"]["identifier"]
    assert_equal "Uni", data["about"]["name"]
    # softwareVersion comes from contract.compiler_version — locks the helper→view wiring.
    assert_equal contract.compiler_version, data["about"]["softwareVersion"]
  end

  test "contract page emits BreadcrumbList JSON-LD with Smarts → contract trail" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)

    breadcrumb = response.body.scan(%r{<script type="application/ld\+json">(.+?)</script>}m)
                               .map { |m| JSON.parse(m[0]) }
                               .find { |j| j["@type"] == "BreadcrumbList" }

    assert breadcrumb, "expected a BreadcrumbList JSON-LD on the contract page"
    assert_equal 2, breadcrumb["itemListElement"].size
    assert_equal "Smarts", breadcrumb["itemListElement"][0]["name"]
    assert_equal "Uni on Ethereum", breadcrumb["itemListElement"][1]["name"]
    assert_match %r{smarts\.md/}, breadcrumb["itemListElement"][1]["item"]
  end

  # show.html.erb picks between two description templates based on whether
  # the classifier returned anything. Without this test the unclassified
  # branch would only surface in production on some weird contract.
  test "contract page description falls back to display-address form when no classification" do
    contract = contracts(:uni_token)

    stub_class_method(ContractDocument::Classifier, :call, ->(_) { nil }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match %r{<meta property="og:description" content="Live on-chain docs for Uni at #{Regexp.escape(contract.display_address)} on Ethereum\.}, response.body
    refute_match %r{<meta property="og:description" content="[^"]*\(ERC-20 Token\)}, response.body
  end

  # When the on-chain ERC-20 name() call succeeds, every page-level display
  # point — H1, <title>, og:title, breadcrumb entry, JSON-LD about.name —
  # must switch to the brand name, not the Solidity class name Etherscan
  # returned. Regression locks on the "FiatTokenV2_2 vs USD Coin" bug.
  test "contract page uses on-chain name() as the display name across title, H1, OG, breadcrumb, and JSON-LD" do
    contract = contracts(:uni_token)
    contract.update!(name: "FiatTokenV2_2")

    brand_name = ChainReader::Multicall3Client::Result.new(success: true, values: [ "USD Coin" ])
    brand_symbol = ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ])

    stub_class_method(ChainReader::ViewCaller, :call,
      ->(_c) { { "name()" => brand_name, "symbol()" => brand_symbol } }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_select "h1", "USD Coin"
    assert_match %r{<title>USD Coin on Ethereum — live on-chain contract docs \| smarts.md</title>}, response.body
    assert_match %r{<meta property="og:title" content="USD Coin on Ethereum — live on-chain contract docs \| smarts.md">}, response.body

    breadcrumb = response.body.scan(%r{<script type="application/ld\+json">(.+?)</script>}m)
                              .map { |m| JSON.parse(m[0]) }
                              .find { |j| j["@type"] == "BreadcrumbList" }
    assert_equal "USD Coin on Ethereum", breadcrumb["itemListElement"][1]["name"]

    webpage = response.body.scan(%r{<script type="application/ld\+json">(.+?)</script>}m)
                            .map { |m| JSON.parse(m[0]) }
                            .find { |j| j["@type"] == "WebPage" }
    assert_equal "USD Coin", webpage["about"]["name"]

    refute_match "FiatTokenV2_2", response.body, "Solidity class name must not leak anywhere on the rendered page"
  end

  # The SEO helper runs in the layout, which is shared with error-state views.
  # If a helper call raises or emits nothing on these pages, a future change
  # would degrade our 404/500 discoverability without any louder signal.
  test "not_verified page still renders layout meta tags via the SEO helper" do
    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ { "ABI" => "Contract source code not verified" } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    stub_class_method(ChainReader::AddressInspector, :call,
      ->(**_) { ChainReader::AddressInspector::Result.new(is_contract: true, balance_wei: 0, tx_count: 0, ens_name: nil) }) do
      get contract_path(chain: "eth", address: "0x0000000000000000000000000000000000000001")
    end

    assert_response :not_found
    # Falls back to site-wide default title since not_verified.html.erb doesn't set its own.
    assert_match %r{<title>#{Regexp.escape(SeoHelper::DEFAULT_TITLE)}</title>}, response.body
    assert_match %r{<meta property="og:site_name" content="Smarts">}, response.body
    assert_match %r{<meta name="description"}, response.body
  end

  # ---------- MCP info card ----------

  test "contract page shows the MCP info card with slug reference for sluged contracts" do
    contract = contracts(:uni_token)
    contract.update!(address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984") # uni-eth
    get "/uni-eth"

    assert_response :success
    assert_match "Query this contract from your AI", response.body
    # Reference shows the slug prominently + address as secondary
    assert_match "uni-eth", response.body
    assert_match "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984", response.body
    # Sample prompt uses the slug
    assert_match "Tell me the current state of uni-eth", response.body
    # Setup pointer
    assert_match "mcp.smarts.md", response.body
  end

  test "contract page shows the MCP info card with chain/address reference for non-sluged contracts" do
    contract = contracts(:uni_token) # fixture at 0x1111... (no slug)
    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    assert_match "Query this contract from your AI", response.body
    # Sample prompt falls back to chain/address when no slug exists
    assert_match "Tell me the current state of eth/0x1111111111111111111111111111111111111111", response.body
  end

  # Clipboard is driven entirely by `data-copy-text-value`. If someone
  # refactors the partial and mis-templates the attribute, copy buttons
  # would silently write the wrong string (or empty). This assert locks
  # the slug-button's value down.
  test "copy button for the slug reference carries the correct data-copy-text-value" do
    contract = contracts(:uni_token)
    contract.update!(address: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    get "/uni-eth"

    assert_match %r{data-copy-text-value="uni-eth"}, response.body
    assert_match %r{data-copy-text-value="Tell me the current state of uni-eth"}, response.body
  end

  # The MCP card sits OUTSIDE the `if @protocol_adapter` branch in show.html.erb.
  # A refactor that moves it inside would make the card disappear from every
  # adapter-backed page (USDC, Uniswap V3, …) — i.e. exactly the pages where
  # the AI integration matters most. This test stubs an adapter and asserts
  # both renders happen.
  test "MCP card renders alongside the protocol adapter panel (not inside it)" do
    contract = contracts(:uni_token)

    fake_adapter = ProtocolAdapters::UniswapV3Adapter.allocate
    fake_adapter.instance_variable_set(:@contract, contract)
    fake_adapter.instance_variable_set(:@chain, contract.chain)
    # panel_data returning {error:} drives the partial's error branch —
    # enough to prove the adapter template rendered without needing live data.
    fake_adapter.define_singleton_method(:panel_data) { { error: "stubbed for test" } }

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_) { fake_adapter }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "Query this contract from your AI", response.body, "MCP card must render"
    assert_match "stubbed for test", response.body, "adapter panel must render alongside"
  end

  test "show fetches from etherscan when contract not in db" do
    stub_etherscan_full

    get contract_path(chain: "eth", address: "0x2222222222222222222222222222222222222222")

    assert_response :success
    assert_select "h1", "TetherToken"
    assert Contract.exists?(address: "0x2222222222222222222222222222222222222222")
  end

  test "show extracts and persists NatSpec end-to-end on first fetch" do
    stub_etherscan_full(source_code: <<~SOL)
      contract TetherToken {
        /// @notice Total supply of USDT.
        function totalSupply() external view returns (uint256) {}
      }
    SOL

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: "0x2222222222222222222222222222222222222222")
    end

    persisted = Contract.find_by!(address: "0x2222222222222222222222222222222222222222")
    assert_equal "Total supply of USDT.", persisted.natspec.dig("functions", "totalSupply", "notice")
    assert_match "Total supply of USDT.", response.body
  end

  test "show returns 404 for unverified contract" do
    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ { "ABI" => "Contract source code not verified" } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    stub_class_method(ChainReader::AddressInspector, :call,
      ->(**_) { ChainReader::AddressInspector::Result.new(is_contract: true, balance_wei: 0, tx_count: 0, ens_name: nil) }) do
      get contract_path(chain: "eth", address: "0x0000000000000000000000000000000000000001")
    end
    assert_response :not_found
  end

  test "not_verified page renders wallet-address copy when inspection reports an EOA" do
    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ { "ABI" => "Contract source code not verified" } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    eoa_result = ChainReader::AddressInspector::Result.new(
      is_contract: false, balance_wei: 1_800_000_000_000_000_000, tx_count: 42, ens_name: "vitalik.eth"
    )
    stub_class_method(ChainReader::AddressInspector, :call, ->(**_) { eoa_result }) do
      get contract_path(chain: "eth", address: "0xd8da6bf26964af9d7eed9e03e53415d37aa96045")
    end

    assert_response :not_found
    assert_match "Wallet address", response.body
    assert_match "vitalik.eth", response.body
    assert_match "1.80 ETH", response.body
    assert_match "Transactions sent", response.body
  end

  test "show returns 404 for unknown chain" do
    get contract_path(chain: "solana", address: "0x0000000000000000000000000000000000000001")
    assert_response :not_found
  end

  test "show renders live on-chain values inline next to view functions" do
    contract = contracts(:uni_token)
    live_values = {
      "totalSupply()" => ChainReader::Multicall3Client::Result.new(success: true, values: [ 1_000_000_000_000_000_000_000_000_000 ])
    }

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { live_values }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "1,000,000,000,000,000,000,000,000,000", response.body
    assert_match "→", response.body
  end

  test "show renders NatSpec notice inline for documented functions" do
    contract = contracts(:uni_token)
    contract.update!(natspec: {
      "functions" => { "totalSupply" => { "notice" => "Total tokens in circulation." } }
    })

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "Total tokens in circulation.", response.body
  end

  test "show renders Source tab with highlighted source code" do
    contract = contracts(:uni_token)
    contract.update!(source_code: "contract Token { uint256 x; }")

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match 'aria-label="Source"', response.body
    assert_match 'class="highlight', response.body
  end

  test "show renders @dev alert, @param and @return descriptions inline" do
    contract = contracts(:uni_token)
    contract.update!(natspec: {
      "functions" => {
        "approve" => {
          "notice" => "Approve a spender.",
          "dev"    => "Subject to the usual ERC-20 race condition.",
          "params" => { "spender" => "Who may spend.", "rawAmount" => "Token allowance." },
          "returns" => [ "True on success." ]
        }
      }
    })

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_match "Subject to the usual ERC-20 race condition.", response.body
    assert_match "Who may spend.", response.body
    assert_match "Token allowance.", response.body
    assert_match "True on success.", response.body
    assert_match "alert-info", response.body
  end

  test "show renders one radio tab per file for multi-file Solidity standard JSON" do
    contract = contracts(:uni_token)
    multi_file_source = "{" + {
      language: "Solidity",
      sources: {
        "contracts/Token.sol"        => { "content" => "contract Token {}" },
        "contracts/interfaces/IERC.sol" => { "content" => "interface IERC {}" }
      }
    }.to_json + "}"
    contract.update!(source_code: multi_file_source)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match 'name="source_file"', response.body
    assert_match 'aria-label="Token.sol"', response.body
    assert_match 'aria-label="IERC.sol"', response.body
  end

  test "show renders classification badge for a classifiable contract" do
    # uni_token fixture has an ERC-20 method in its ABI. Add the full set so
    # the classifier picks it up.
    contract = contracts(:uni_token)
    contract.update!(abi: erc20_like_abi)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "ERC-20 Token", response.body
    assert_match "Fungible token following the ERC-20 standard", response.body
  end

  test "show tolerates classifier failure and still renders the page" do
    contract = contracts(:uni_token)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(ContractDocument::Classifier, :call, ->(_c) { raise "classifier bug" }) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end

    assert_response :success
    refute_match "ERC-20 Token", response.body
  end

  test "show enqueues EnrichContractAiJob when ai_natspec is missing and some function lacks real natspec" do
    contract = contracts(:uni_token)
    contract.update!(natspec: {}, ai_natspec: nil)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      assert_enqueued_with(job: EnrichContractAiJob, args: [ contract ]) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end
  end

  test "show does not enqueue AI job when contract ABI is empty (no functions to document)" do
    # Simulate a verified contract whose parsed ABI is [] — e.g. a Solidity
    # library with no public functions. The enqueue guard must skip it.
    stub_etherscan_full_with_empty_abi

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      assert_no_enqueued_jobs(only: EnrichContractAiJob) do
        get contract_path(chain: "eth", address: "0x2222222222222222222222222222222222222222")
      end
    end
  end

  test "show does not enqueue AI job when ai_natspec already present" do
    contract = contracts(:uni_token)
    contract.update!(ai_natspec: { "functions" => { "transfer" => { "notice" => "x" } } })

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      assert_no_enqueued_jobs(only: EnrichContractAiJob) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end
  end

  test "show does not enqueue AI job when all functions already have real natspec" do
    contract = contracts(:uni_token)
    all_names = (contract.view_functions + contract.write_functions).map { |f| f["name"] }
    contract.update!(
      natspec: { "functions" => all_names.to_h { |n| [ n, { "notice" => "documented" } ] } },
      ai_natspec: nil
    )

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      assert_no_enqueued_jobs(only: EnrichContractAiJob) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end
  end

  test "show tolerates AI job enqueue failure (queue backend down)" do
    contract = contracts(:uni_token)
    contract.update!(natspec: {}, ai_natspec: nil)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(EnrichContractAiJob, :perform_later, ->(_c) { raise "queue down" }) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end

    assert_response :success
    assert_select "h1", contract.name
  end

  test "show renders an em-dash placeholder for unnamed input/output parameters" do
    contract = contracts(:uni_token)

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "opacity-40", response.body
    refute_match "(unnamed)", response.body
  end

  test "show renders ✨ AI badge next to AI-generated descriptions" do
    contract = contracts(:uni_token)
    contract.update!(
      natspec: nil,
      ai_natspec: {
        "functions" => { "totalSupply" => { "notice" => "Generated by Claude." } }
      }
    )

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_match "Generated by Claude.", response.body
    assert_match "✨ AI", response.body
  end

  test "show tolerates protocol-adapter failure and renders the page without a panel" do
    contract = contracts(:uni_token)
    crashing = ->(_c) { raise StandardError, "adapter bug" }

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      stub_class_method(ProtocolAdapters::Base, :resolve, crashing) do
        get contract_path(chain: "eth", address: contract.address)
      end
    end

    assert_response :success
    refute_match "Uniswap V3", response.body
  end

  test "show tolerates live-value failure and still renders page" do
    contract = contracts(:uni_token)
    raising = ->(_c) { raise ChainReader::Base::RpcError, "rpc down" }

    stub_class_method(ChainReader::ViewCaller, :call, raising) do
      get contract_path(chain: "eth", address: contract.address)
    end

    assert_response :success
    assert_select "h1", contract.name
  end

  private

  def erc20_like_abi
    %w[totalSupply balanceOf(address) transfer(address,uint256)
       transferFrom(address,address,uint256) approve(address,uint256)
       allowance(address,address)].map do |sig|
      name, args = sig.split("(")
      arg_types = args.to_s.chomp(")").split(",").reject(&:empty?)
      {
        "type" => "function", "name" => name,
        "inputs" => arg_types.map { |t| { "type" => t } },
        "outputs" => [],
        "stateMutability" => "view"
      }
    end
  end

  def stub_etherscan_full_with_empty_abi
    source_body = {
      "status" => "1", "message" => "OK",
      "result" => [ {
        "ContractName" => "EmptyAbiContract", "CompilerVersion" => "v0.8.0",
        "SourceCode" => "library Empty {}", "ABI" => "[]",
        "OptimizationUsed" => "0", "Runs" => "0",
        "EVMVersion" => "default", "LicenseType" => "MIT"
      } ]
    }
    abi_body = { "status" => "1", "message" => "OK", "result" => "[]" }

    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200, body: source_body.to_json, headers: { "Content-Type" => "application/json" }
    )
    stub_request(:get, /api\.etherscan\.io.*getabi/).to_return(
      status: 200, body: abi_body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_etherscan_full(source_code: "contract TetherToken {}")
    source_body = {
      "status" => "1", "message" => "OK",
      "result" => [ {
        "ContractName" => "TetherToken",
        "CompilerVersion" => "v0.4.18",
        "SourceCode" => source_code,
        "ABI" => '[{"type":"function","name":"totalSupply","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"}]',
        "OptimizationUsed" => "1",
        "Runs" => "200",
        "EVMVersion" => "default",
        "LicenseType" => "MIT"
      } ]
    }

    abi_body = {
      "status" => "1", "message" => "OK",
      "result" => '[{"type":"function","name":"totalSupply","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"}]'
    }

    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200, body: source_body.to_json, headers: { "Content-Type" => "application/json" }
    )
    stub_request(:get, /api\.etherscan\.io.*getabi/).to_return(
      status: 200, body: abi_body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end
end
