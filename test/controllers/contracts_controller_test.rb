require "test_helper"

class ContractsControllerTest < ActionDispatch::IntegrationTest
  test "show renders existing contract" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    assert_select "h1", "Uni"
  end

  test "show fetches from etherscan when contract not in db" do
    stub_etherscan_full

    get contract_path(chain: "eth", address: "0xdac17f958d2ee523a2206206994597c13d831ec7")

    assert_response :success
    assert_select "h1", "TetherToken"
    assert Contract.exists?(address: "0xdac17f958d2ee523a2206206994597c13d831ec7")
  end

  test "show extracts and persists NatSpec end-to-end on first fetch" do
    stub_etherscan_full(source_code: <<~SOL)
      contract TetherToken {
        /// @notice Total supply of USDT.
        function totalSupply() external view returns (uint256) {}
      }
    SOL

    stub_class_method(ChainReader::ViewCaller, :call, ->(_c) { {} }) do
      get contract_path(chain: "eth", address: "0xdac17f958d2ee523a2206206994597c13d831ec7")
    end

    persisted = Contract.find_by!(address: "0xdac17f958d2ee523a2206206994597c13d831ec7")
    assert_equal "Total supply of USDT.", persisted.natspec.dig("functions", "totalSupply", "notice")
    assert_match "Total supply of USDT.", response.body
  end

  test "show returns 404 for unverified contract" do
    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ { "ABI" => "Contract source code not verified" } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    get contract_path(chain: "eth", address: "0x0000000000000000000000000000000000000001")
    assert_response :not_found
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
