# Asks several explorer clients in order and returns the first one that has
# the contract verified. Used where no single index is complete (Arc: Sourcify
# plus ArcScan via Etherscan V2).
#
# Raises NotVerifiedError only when every client says "not verified". If any
# client failed for another reason (rate limit, outage) and none succeeded,
# that error is raised instead, so a transient outage is not reported to the
# user as an unverified contract.
class FallbackExplorerClient < ExplorerClient
  attr_reader :clients

  def initialize(chain, *clients)
    super(chain)
    @clients = clients
  end

  def logs_supported?
    false
  end

  def fetch_contract_info(address)
    not_verified = nil
    failure = nil

    clients.each do |client|
      return client.fetch_contract_info(address)
    rescue NotVerifiedError => e
      not_verified = e
    rescue Error => e
      failure = e
    end

    raise failure || not_verified
  end
end
