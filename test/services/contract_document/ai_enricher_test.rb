require "test_helper"

class ContractDocument::AiEnricherTest < ActiveSupport::TestCase
  FakeChat = Struct.new(:canned) do
    def ask(_prompt)
      response = Struct.new(:content).new(canned)
      response
    end
  end

  setup do
    @chain = chains(:ethereum)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "returns empty functions hash when contract has no ABI" do
    contract = contracts(:empty_contract)
    result = ContractDocument::AiEnricher.call(contract)
    assert_equal({ "functions" => {} }, result)
  end

  test "generates docs for functions that have no real NatSpec" do
    contract = build_contract_with_abi(abi_two_functions)
    canned = claude_json(notice: "Transfers tokens.", params: { "to" => "Recipient" }, returns: [ "Success flag." ])

    stub_class_method(RubyLLM, :chat, ->(**_) { FakeChat.new(canned) }) do
      result = ContractDocument::AiEnricher.call(contract)

      doc = result.dig("functions", "transfer")
      assert_equal "Transfers tokens.", doc["notice"]
      assert_equal "Recipient", doc["params"]["to"]
      assert_equal [ "Success flag." ], doc["returns"]
    end
  end

  test "skips functions that already have real NatSpec notice" do
    contract = build_contract_with_abi(abi_two_functions)
    contract.update!(natspec: {
      "functions" => { "transfer" => { "notice" => "Already documented." } }
    })

    invocations = 0
    chat_stub = ->(**_) {
      invocations += 1
      FakeChat.new(claude_json(notice: "Skipped."))
    }

    stub_class_method(RubyLLM, :chat, chat_stub) do
      result = ContractDocument::AiEnricher.call(contract)
      refute_includes result["functions"].keys, "transfer", "should skip already-documented function"
      assert_includes result["functions"].keys, "balanceOf", "should still enrich undocumented one"
    end
  end

  test "caches per (abi_hash, prompt_version, function_signature)" do
    contract = build_contract_with_abi(abi_two_functions)
    canned = claude_json(notice: "Cached response.")

    invocations = 0
    chat_stub = ->(**_) { invocations += 1; FakeChat.new(canned) }

    stub_class_method(RubyLLM, :chat, chat_stub) do
      ContractDocument::AiEnricher.call(contract)
      ContractDocument::AiEnricher.call(contract)
      ContractDocument::AiEnricher.call(contract)
    end

    assert_equal 2, invocations, "Claude should be asked once per function on the first run only"
  end

  test "tolerates malformed JSON responses by returning no doc for that function" do
    contract = build_contract_with_abi([ abi_fn("transfer", inputs: [ "address", "uint256" ]) ])

    stub_class_method(RubyLLM, :chat, ->(**_) { FakeChat.new("sure here is some nonsense") }) do
      result = ContractDocument::AiEnricher.call(contract)
      assert_empty result["functions"], "malformed JSON should be dropped, not stored"
    end
  end

  test "tolerates RubyLLM errors and returns what it has" do
    contract = build_contract_with_abi(abi_two_functions)

    stub_class_method(RubyLLM, :chat, ->(**_) { raise "claude down" }) do
      result = ContractDocument::AiEnricher.call(contract)
      assert_equal({ "functions" => {} }, result)
    end
  end

  test "drops response when valid JSON has no notice field" do
    contract = build_contract_with_abi([ abi_fn("transfer", inputs: [ "address" ]) ])
    canned = { "dev" => "only a dev note", "params" => {}, "returns" => [] }.to_json

    stub_class_method(RubyLLM, :chat, ->(**_) { FakeChat.new(canned) }) do
      result = ContractDocument::AiEnricher.call(contract)
      assert_empty result["functions"], "JSON without a notice string should be dropped"
    end
  end

  test "drops response when notice is whitespace-only" do
    contract = build_contract_with_abi([ abi_fn("transfer", inputs: [ "address" ]) ])
    canned = { "notice" => "   ", "params" => {}, "returns" => [] }.to_json

    stub_class_method(RubyLLM, :chat, ->(**_) { FakeChat.new(canned) }) do
      result = ContractDocument::AiEnricher.call(contract)
      assert_empty result["functions"], "Whitespace-only notice should not be stored"
    end
  end

  test "strips markdown code fences around Claude's JSON response" do
    contract = build_contract_with_abi([ abi_fn("transfer", inputs: [ "address", "uint256" ]) ])
    canned = "```json\n#{claude_json(notice: 'Fenced response.')}\n```"

    stub_class_method(RubyLLM, :chat, ->(**_) { FakeChat.new(canned) }) do
      result = ContractDocument::AiEnricher.call(contract)
      assert_equal "Fenced response.", result.dig("functions", "transfer", "notice")
    end
  end

  test "caps enrichment at MAX_FUNCTIONS_PER_CONTRACT to protect latency/cost" do
    funcs = 40.times.map { |i| abi_fn("fn_#{i}") }
    contract = build_contract_with_abi(funcs)

    invocations = 0
    stub_class_method(RubyLLM, :chat, ->(**_) {
      invocations += 1
      FakeChat.new(claude_json(notice: "A short note."))
    }) do
      ContractDocument::AiEnricher.call(contract)
    end

    assert_equal ContractDocument::AiEnricher::MAX_FUNCTIONS_PER_CONTRACT, invocations
  end

  test "includes Polymarket architecture context in generated source docs prompt" do
    contract = build_contract_with_abi(
      [ abi_fn("matchOrders", inputs: [ "bytes32" ]) ],
      chain: chains(:polygon),
      address: "0x4bfb41d5b3570defd03c39a9a4d8de6bd8b8982e"
    )
    captured_prompt = nil

    chat = Object.new
    chat.define_singleton_method(:ask) do |prompt|
      captured_prompt = prompt
      Struct.new(:content).new(claude_json(notice: "Matches Polymarket orders."))
    end

    stub_class_method(RubyLLM, :chat, ->(**_) { chat }) do
      ContractDocument::AiEnricher.call(contract)
    end

    assert_includes captured_prompt, "Protocol: Polymarket"
    assert_includes captured_prompt, "Contract role: Polymarket CTF Exchange"
    assert_includes captured_prompt, "Architecture context: Matches orders for binary Polymarket markets."
    assert_includes captured_prompt, "Exchange distinction: Shares the same trading ABI as the Neg-Risk Exchange"
  end

  private

  def abi_fn(name, inputs: [], outputs: [ "bool" ], mutability: "nonpayable")
    {
      "type" => "function",
      "name" => name,
      "inputs" => inputs.map { |t| { "type" => t } },
      "outputs" => outputs.map { |t| { "type" => t } },
      "stateMutability" => mutability
    }
  end

  def abi_two_functions
    [
      abi_fn("transfer", inputs: [ "address", "uint256" ]),
      abi_fn("balanceOf", inputs: [ "address" ], mutability: "view")
    ]
  end

  def build_contract_with_abi(abi, chain: @chain, address: nil)
    Contract.create!(chain: chain, address: address || "0x" + SecureRandom.hex(20), abi: abi)
  end

  def claude_json(notice:, dev: nil, params: {}, returns: [])
    { "notice" => notice, "dev" => dev, "params" => params, "returns" => returns }.to_json
  end
end
