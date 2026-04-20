class CreateContracts < ActiveRecord::Migration[8.1]
  def change
    create_table :contracts do |t|
      t.references :chain, null: false, foreign_key: true
      t.string :address, null: false
      t.string :name
      t.string :compiler_version
      t.jsonb :abi
      t.text :source_code
      t.jsonb :natspec
      t.string :contract_type
      t.datetime :verified_at

      t.timestamps
    end

    add_index :contracts, [ :chain_id, :address ], unique: true
  end
end
