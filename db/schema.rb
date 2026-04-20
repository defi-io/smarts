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

ActiveRecord::Schema[8.1].define(version: 2026_04_20_205830) do
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
    t.bigint "chain_id", null: false
    t.string "compiler_version"
    t.string "contract_type"
    t.datetime "created_at", null: false
    t.string "name"
    t.jsonb "natspec"
    t.text "source_code"
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index ["chain_id", "address"], name: "index_contracts_on_chain_id_and_address", unique: true
    t.index ["chain_id"], name: "index_contracts_on_chain_id"
  end

  add_foreign_key "contracts", "chains"
end
