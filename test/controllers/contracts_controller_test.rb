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
        get contract_path(chain: "eth", address: "0xdac17f958d2ee523a2206206994597c13d831ec7")
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
