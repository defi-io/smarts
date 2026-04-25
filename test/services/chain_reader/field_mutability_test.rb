require "test_helper"

class ChainReader::FieldMutabilityTest < ActiveSupport::TestCase
  test "ERC-20 metadata fields classify as immutable" do
    %w[name symbol decimals].each do |fn|
      assert_equal :immutable, ChainReader::FieldMutability.classify(fn),
                   "#{fn} should be :immutable so the UI doesn't show 'X seconds ago' next to it"
    end
  end

  test "Uniswap V3 pool constructor-set fields classify as immutable" do
    %w[factory token0 token1 fee tickSpacing].each do |fn|
      assert_equal :immutable, ChainReader::FieldMutability.classify(fn)
    end
  end

  test "admin / governance fields classify as :slow (block but no timestamp)" do
    %w[owner paused pauser blacklister implementation upgradedAddress].each do |fn|
      assert_equal :slow, ChainReader::FieldMutability.classify(fn)
    end
  end

  test "unknown / non-whitelisted fields classify as :fast (full freshness shown)" do
    %w[liquidity slot0 totalSupply getReserves utilizationRate].each do |fn|
      assert_equal :fast, ChainReader::FieldMutability.classify(fn),
                   "#{fn} should default to :fast so we surface live block + age"
    end
  end
end
