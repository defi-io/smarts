class CreateChains < ActiveRecord::Migration[8.1]
  def change
    create_table :chains do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.integer :chain_id, null: false
      t.string :explorer_api_url, null: false
      t.string :rpc_url

      t.timestamps
    end

    add_index :chains, :slug, unique: true
    add_index :chains, :chain_id, unique: true
  end
end
