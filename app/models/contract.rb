class Contract < ApplicationRecord
  belongs_to :chain

  validates :address, presence: true
  validates :address, uniqueness: { scope: :chain_id }

  before_validation :normalize_address

  def display_address
    "#{address[0..5]}...#{address[-4..]}"
  end

  def view_functions
    return [] unless abi.is_a?(Array)

    abi.select { |item| item["type"] == "function" && item["stateMutability"].in?(%w[view pure]) }
  end

  def write_functions
    return [] unless abi.is_a?(Array)

    abi.select { |item| item["type"] == "function" && item["stateMutability"].in?(%w[nonpayable payable]) }
  end

  def events
    return [] unless abi.is_a?(Array)

    abi.select { |item| item["type"] == "event" }
  end

  # Returns {"notice" => ..., "dev" => ..., "params" => {...}, "returns" => [...]}
  # or {} if no docs are present for this function/event.
  def natspec_for(kind, name)
    return {} unless natspec.is_a?(Hash)

    natspec.dig(kind, name) || {}
  end

  private

  def normalize_address
    self.address = address&.downcase
  end
end
