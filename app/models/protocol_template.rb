class ProtocolTemplate < ApplicationRecord
  MATCH_TYPES = %w[required_selectors].freeze

  validates :protocol_key, :display_name, :match_type, presence: true
  validates :protocol_key, uniqueness: true
  validates :match_type, inclusion: { in: MATCH_TYPES }
  validates :required_selectors, presence: true

  # Lower priority = more specific = matched first. Uniswap V3 Pool (priority
  # 10) should match before generic ERC-20 (priority 100).
  scope :by_priority, -> { order(:priority) }

  def required_selectors_set
    @required_selectors_set ||= Set.new(Array(required_selectors).map(&:downcase))
  end
end
