class GovernanceEvent < ApplicationRecord
  belongs_to :contract

  CATEGORIES = %w[role_change config upgrade lifecycle risk_action].freeze

  validates :block_number, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :tx_hash, presence: true
  validates :log_index, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :event_name, presence: true
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :tx_hash, uniqueness: { scope: [ :contract_id, :log_index ] }

  scope :newest_first, -> { order(block_number: :desc, log_index: :desc) }
  scope :by_category, ->(category) { where(category: category) }
  scope :since_block, ->(block) { where("block_number > ?", block) }
end
