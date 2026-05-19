class CreateGovernanceEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :governance_events do |t|
      t.references :contract, null: false, foreign_key: true
      t.bigint :block_number, null: false
      t.string :tx_hash, null: false
      t.integer :log_index, null: false
      t.string :event_name, null: false
      t.string :category, null: false
      t.jsonb :args, null: false, default: {}
      t.string :summary
      t.datetime :block_timestamp

      t.timestamps
    end

    add_index :governance_events, [ :contract_id, :tx_hash, :log_index ], unique: true,
              name: "index_governance_events_unique"
    add_index :governance_events, [ :contract_id, :block_number ],
              order: { block_number: :desc },
              name: "index_governance_events_on_contract_and_block"
    add_index :governance_events, [ :contract_id, :category ],
              name: "index_governance_events_on_contract_and_category"

    add_column :contracts, :governance_last_scanned_block, :bigint
  end
end
