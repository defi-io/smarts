require "test_helper"

class GetPolymarketPositionToolTest < ActiveSupport::TestCase
  test "wraps position fetcher result" do
    positions = [
      {
        condition_id: "0x" + ("12" * 32),
        slug: "sample",
        outcomes: [ { name: "Yes", balance: 1, redeemable: true } ]
      }
    ]

    stub_class_method(Polymarket::PositionFetcher, :call, ->(**) { positions }) do
      payload = GetPolymarketPositionTool.payload(
        address: "0x000000000000000000000000000000000000beef",
        condition_ids: [ "0x" + ("12" * 32) ]
      )

      assert_equal "Polymarket", payload[:protocol]
      assert_equal positions, payload[:positions]
    end
  end

  test "surfaces validation errors" do
    payload = GetPolymarketPositionTool.payload(address: "not-an-address", condition_ids: [ "0x" + ("12" * 32) ])

    assert_equal "invalid address", payload[:error]
  end
end
