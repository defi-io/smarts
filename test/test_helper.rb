ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

module SilenceEthFrozenStringWarnings
  def warn(message, category: nil, **)
    return if message.is_a?(String) &&
              message.include?("gems/eth-") &&
              message.include?("literal string will be frozen")
    super
  end
end
Warning.singleton_class.prepend(SilenceEthFrozenStringWarnings)

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Minitest 6 dropped Minitest::Mock#stub. Block-scoped singleton-method
    # replacement: stub_impl is a callable (lambda/proc), yielded block runs the test.
    #
    # Special case: when stubbing Multicall3Client.call (which now returns a
    # Batch struct), per-call-Result arrays returned by the stub are auto-
    # wrapped into a Batch with a default block_number. Lets the many
    # existing per-result-array stubs keep working without churn.
    def stub_class_method(receiver, method_name, stub_impl)
      original = receiver.method(method_name)
      wrap_multicall  = (receiver == ChainReader::Multicall3Client && method_name == :call)
      wrap_viewcaller = (receiver == ChainReader::ViewCaller       && method_name == :call)

      receiver.define_singleton_method(method_name) do |*a, **kw, &b|
        result = stub_impl.call(*a, **kw, &b)
        if wrap_multicall && result.is_a?(Array)
          ChainReader::Multicall3Client::Batch.new(block_number: 19_000_000, results: result)
        elsif wrap_viewcaller && result.is_a?(Hash)
          ChainReader::ViewCaller::Snapshot.new(results: result, block_number: 19_000_000, fetched_at: Time.current)
        else
          result
        end
      end
      yield
    ensure
      receiver.define_singleton_method(method_name, original)
    end

    # Wraps a per-call Result array into a Multicall3Client::Batch for stubs.
    # `Multicall3Client.call` now returns a Batch struct (block_number +
    # results); this keeps existing test fixtures terse. Default block_number
    # is high enough to look like a realistic mainnet block in fixtures.
    def batch_of(results, block_number: 19_000_000)
      ChainReader::Multicall3Client::Batch.new(block_number: block_number, results: results)
    end
  end
end
