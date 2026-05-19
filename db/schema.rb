# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_18_221905) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "chains", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.datetime "created_at", null: false
    t.string "explorer_api_url", null: false
    t.string "name", null: false
    t.string "rpc_url"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["chain_id"], name: "index_chains_on_chain_id", unique: true
    t.index ["slug"], name: "index_chains_on_slug", unique: true
  end

  create_table "contracts", force: :cascade do |t|
    t.jsonb "abi"
    t.string "address", null: false
    t.jsonb "ai_natspec"
    t.bigint "chain_id", null: false
    t.string "compiler_version"
    t.string "contract_type"
    t.datetime "created_at", null: false
    t.bigint "governance_last_scanned_block"
    t.string "implementation_address"
    t.string "name"
    t.jsonb "natspec"
    t.text "source_code"
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index ["chain_id", "address"], name: "index_contracts_on_chain_id_and_address", unique: true
    t.index ["chain_id"], name: "index_contracts_on_chain_id"
  end

  create_table "governance_events", force: :cascade do |t|
    t.jsonb "args", default: {}, null: false
    t.bigint "block_number", null: false
    t.datetime "block_timestamp"
    t.string "category", null: false
    t.bigint "contract_id", null: false
    t.datetime "created_at", null: false
    t.string "event_name", null: false
    t.integer "log_index", null: false
    t.string "summary"
    t.string "tx_hash", null: false
    t.datetime "updated_at", null: false
    t.index ["contract_id", "block_number"], name: "index_governance_events_on_contract_and_block", order: { block_number: :desc }
    t.index ["contract_id", "category"], name: "index_governance_events_on_contract_and_category"
    t.index ["contract_id", "tx_hash", "log_index"], name: "index_governance_events_unique", unique: true
    t.index ["contract_id"], name: "index_governance_events_on_contract_id"
  end

  create_table "protocol_templates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description"
    t.string "display_name", null: false
    t.string "match_type", null: false
    t.integer "priority", default: 100, null: false
    t.string "protocol_key", null: false
    t.jsonb "required_selectors", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["match_type", "priority"], name: "index_protocol_templates_on_match_type_and_priority"
    t.index ["protocol_key"], name: "index_protocol_templates_on_protocol_key", unique: true
  end

  add_foreign_key "contracts", "chains"
  add_foreign_key "governance_events", "contracts"
end
