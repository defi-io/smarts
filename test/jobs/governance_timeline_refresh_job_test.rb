require "test_helper"

class GovernanceTimelineRefreshJobTest < ActiveJob::TestCase
  setup do
    @contract = contracts(:uni_token)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "runs TimelineFetcher and broadcasts a turbo refresh" do
    fetcher_calls = []
    broadcasts = []
    fake_result = GovernanceEvents::TimelineFetcher::Result.new(
      contract: @contract.address, chain: "eth",
      total_events: 0, newly_fetched: 0, latest_block: 1, events: [], error: nil
    )

    stub_class_method(GovernanceEvents::TimelineFetcher, :call, ->(**kwargs) {
      fetcher_calls << kwargs[:contract]
      fake_result
    }) do
      stub_class_method(Turbo::StreamsChannel, :broadcast_refresh_to, ->(*targets, **_) {
        broadcasts << targets
      }) do
        GovernanceTimelineRefreshJob.perform_now(@contract.id)
      end
    end

    assert_equal [ @contract ], fetcher_calls
    assert_equal 1, broadcasts.size
    assert_equal @contract, broadcasts.first.first
  end

  test "marks the contract fresh in Rails.cache after running" do
    fake_result = GovernanceEvents::TimelineFetcher::Result.new(
      contract: @contract.address, chain: "eth",
      total_events: 0, newly_fetched: 0, latest_block: 1, events: [], error: nil
    )

    refute GovernanceTimelineRefreshJob.fresh?(@contract)

    stub_class_method(GovernanceEvents::TimelineFetcher, :call, ->(**_) { fake_result }) do
      stub_class_method(Turbo::StreamsChannel, :broadcast_refresh_to, ->(*_, **_) { }) do
        GovernanceTimelineRefreshJob.perform_now(@contract.id)
      end
    end

    assert GovernanceTimelineRefreshJob.fresh?(@contract)
  end

  test "is a no-op when contract no longer exists" do
    broadcasts = []
    stub_class_method(Turbo::StreamsChannel, :broadcast_refresh_to, ->(*t, **_) { broadcasts << t }) do
      assert_nothing_raised do
        GovernanceTimelineRefreshJob.perform_now(0)
      end
    end
    assert_empty broadcasts
  end

  test "still marks fresh and broadcasts when TimelineFetcher reports partial error" do
    partial = GovernanceEvents::TimelineFetcher::Result.new(
      contract: @contract.address, chain: "eth",
      total_events: 0, newly_fetched: 0, latest_block: 1,
      events: [], error: "partial scan: Pause: rate limit"
    )

    broadcasts = []
    stub_class_method(GovernanceEvents::TimelineFetcher, :call, ->(**_) { partial }) do
      stub_class_method(Turbo::StreamsChannel, :broadcast_refresh_to, ->(*t, **_) { broadcasts << t }) do
        GovernanceTimelineRefreshJob.perform_now(@contract.id)
      end
    end

    assert GovernanceTimelineRefreshJob.fresh?(@contract)
    assert_equal 1, broadcasts.size
  end

  test "fresh? returns false when no cache key exists" do
    refute GovernanceTimelineRefreshJob.fresh?(@contract)
  end
end
