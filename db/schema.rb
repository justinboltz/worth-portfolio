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

ActiveRecord::Schema[7.2].define(version: 2026_11_23_221436) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "plaid_item_id"
    t.string "plaid_account_id"
    t.string "name", null: false
    t.string "official_name"
    t.string "account_type", null: false
    t.string "subtype"
    t.string "mask"
    t.string "iso_currency_code"
    t.decimal "current_balance", precision: 19, scale: 4
    t.decimal "available_balance", precision: 19, scale: 4
    t.decimal "limit_balance", precision: 19, scale: 4
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "tracked", default: true, null: false
    t.string "import_source_key"
    t.jsonb "import_metadata", default: {}, null: false
    t.boolean "net_worth_excluded", default: false, null: false
    t.index ["plaid_account_id"], name: "index_accounts_on_plaid_account_id", unique: true
    t.index ["plaid_item_id"], name: "index_accounts_on_plaid_item_id"
    t.index ["user_id", "import_source_key"], name: "index_accounts_on_user_id_and_import_source_key", unique: true, where: "(import_source_key IS NOT NULL)"
    t.index ["user_id"], name: "index_accounts_on_user_id"
    t.check_constraint "plaid_item_id IS NOT NULL AND plaid_account_id IS NOT NULL OR import_source_key IS NOT NULL", name: "accounts_have_a_source"
  end

  create_table "asset_valuations", force: :cascade do |t|
    t.bigint "manual_asset_id", null: false
    t.decimal "value", precision: 19, scale: 2, null: false
    t.date "valued_on", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["manual_asset_id", "valued_on"], name: "index_asset_valuations_on_manual_asset_id_and_valued_on", unique: true
    t.index ["manual_asset_id"], name: "index_asset_valuations_on_manual_asset_id"
  end

  create_table "balance_snapshots", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "account_id", null: false
    t.date "as_of_date", null: false
    t.decimal "current_balance", precision: 19, scale: 4
    t.decimal "available_balance", precision: 19, scale: 4
    t.string "iso_currency_code"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "import_metadata", default: {}, null: false
    t.index ["account_id", "as_of_date"], name: "index_balance_snapshots_on_account_id_and_as_of_date", unique: true
    t.index ["account_id"], name: "index_balance_snapshots_on_account_id"
    t.index ["user_id"], name: "index_balance_snapshots_on_user_id"
  end

  create_table "budgets", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "category_id", null: false
    t.decimal "amount", precision: 19, scale: 2, null: false
    t.string "currency", default: "USD", null: false
    t.date "starts_on", null: false
    t.boolean "rollover", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category_id"], name: "index_budgets_on_category_id"
    t.index ["user_id", "category_id"], name: "index_budgets_on_user_id_and_category_id", unique: true
    t.index ["user_id"], name: "index_budgets_on_user_id"
  end

  create_table "categories", force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "parent_id"
    t.string "name", null: false
    t.boolean "system", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_id", "name"], name: "index_categories_on_parent_id_and_name", unique: true, where: "(user_id IS NULL)"
    t.index ["parent_id"], name: "index_categories_on_parent_id"
    t.index ["user_id", "parent_id", "name"], name: "index_categories_on_user_id_and_parent_id_and_name", unique: true
    t.index ["user_id"], name: "index_categories_on_user_id"
  end

  create_table "category_expense_types", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "category_id", null: false
    t.string "expense_type", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category_id"], name: "index_category_expense_types_on_category_id"
    t.index ["user_id", "category_id"], name: "index_category_expense_types_on_user_id_and_category_id", unique: true
    t.index ["user_id"], name: "index_category_expense_types_on_user_id"
    t.check_constraint "expense_type::text = ANY (ARRAY['fixed'::character varying::text, 'variable'::character varying::text, 'unclassified'::character varying::text])", name: "valid_category_expense_type"
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.jsonb "serialized_properties"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_discard"
    t.text "callback_queue_name"
    t.integer "callback_priority"
    t.datetime "enqueued_at"
    t.datetime "discarded_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
    t.index ["created_at", "id"], name: "index_good_job_batches_on_created_at_and_id", order: :desc
    t.index ["finished_at"], name: "index_good_job_batches_on_finished_at", where: "(finished_at IS NOT NULL)"
  end

  create_table "good_job_concurrency_claims", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "job_id", null: false
    t.uuid "locked_by_id"
    t.integer "state", limit: 2, null: false
    t.text "key", null: false
    t.index ["job_id"], name: "index_good_job_concurrency_claims_on_job_id"
    t.index ["key", "job_id"], name: "index_good_job_concurrency_claims_on_key_and_job_id", unique: true
    t.index ["key", "state", "created_at"], name: "index_good_job_concurrency_claims_for_promotion"
    t.index ["locked_by_id"], name: "index_good_job_concurrency_claims_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id", null: false
    t.text "job_class"
    t.text "queue_name"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.text "error"
    t.integer "error_event", limit: 2
    t.text "error_backtrace", array: true
    t.uuid "process_id"
    t.interval "duration"
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["created_at"], name: "index_good_job_executions_on_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
    t.index ["scheduled_at"], name: "index_good_job_executions_on_scheduled_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "state"
    t.integer "lock_type", limit: 2
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "key"
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "queue_name"
    t.integer "priority"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "performed_at"
    t.datetime "finished_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id"
    t.text "concurrency_key"
    t.text "cron_key"
    t.uuid "retried_good_job_id"
    t.datetime "cron_at"
    t.uuid "batch_id"
    t.uuid "batch_callback_id"
    t.boolean "is_discrete"
    t.integer "executions_count"
    t.text "job_class"
    t.integer "error_event", limit: 2
    t.text "labels", array: true
    t.uuid "locked_by_id"
    t.datetime "locked_at"
    t.integer "lock_type", limit: 2
    t.index ["active_job_id", "created_at"], name: "index_good_jobs_on_active_job_id_and_created_at"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id", where: "(batch_callback_id IS NOT NULL)"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id_unfinished", where: "((batch_callback_id IS NOT NULL) AND (finished_at IS NULL))"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id", where: "(batch_id IS NOT NULL)"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id_unfinished", where: "((batch_id IS NOT NULL) AND (finished_at IS NULL))"
    t.index ["concurrency_key", "created_at"], name: "index_good_jobs_on_concurrency_key_and_created_at"
    t.index ["concurrency_key"], name: "index_good_jobs_on_concurrency_key_when_unfinished", where: "(finished_at IS NULL)"
    t.index ["created_at"], name: "index_good_jobs_on_created_at"
    t.index ["cron_key", "created_at"], name: "index_good_jobs_on_cron_key_and_created_at_cond", where: "(cron_key IS NOT NULL)"
    t.index ["cron_key", "cron_at"], name: "index_good_jobs_on_cron_key_and_cron_at_cond", unique: true, order: { cron_at: "DESC NULLS LAST" }, where: "(cron_key IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_jobs_on_finished_at_only", where: "(finished_at IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_on_discarded", order: :desc, where: "((finished_at IS NOT NULL) AND (error IS NOT NULL))"
    t.index ["id"], name: "index_good_jobs_on_unfinished_or_errored", where: "((finished_at IS NULL) OR (error IS NOT NULL))"
    t.index ["job_class", "finished_at"], name: "index_good_jobs_on_discarded_job_class", where: "((finished_at IS NOT NULL) AND (error IS NOT NULL))"
    t.index ["job_class"], name: "index_good_jobs_on_job_class"
    t.index ["labels"], name: "index_good_jobs_on_labels", where: "(labels IS NOT NULL)", using: :gin
    t.index ["locked_by_id"], name: "index_good_jobs_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
    t.index ["priority", "created_at"], name: "index_good_job_jobs_for_candidate_lookup", where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_for_candidate_dequeue_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_on_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["queue_name", "priority", "created_at"], name: "index_good_jobs_dequeue_by_queue", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "priority", "scheduled_at"], name: "index_good_jobs_dequeue_by_queue_scheduled_at", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "scheduled_at", "id"], name: "index_good_jobs_on_queue_name_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["queue_name"], name: "index_good_jobs_on_queue_name"
    t.index ["scheduled_at", "queue_name"], name: "index_good_jobs_on_scheduled_at_and_queue_name"
    t.index ["scheduled_at"], name: "index_good_jobs_on_scheduled_at", where: "(finished_at IS NULL)"
  end

  create_table "import_batches", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "csv_text", null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "imported_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_import_batches_on_user_id"
  end

  create_table "import_profiles", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_import_profiles_on_user_id"
  end

  create_table "institutions", force: :cascade do |t|
    t.string "name", null: false
    t.string "plaid_institution_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["plaid_institution_id"], name: "index_institutions_on_plaid_institution_id", unique: true
  end

  create_table "manual_assets", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.string "asset_type", null: false
    t.decimal "value", precision: 19, scale: 2, null: false
    t.string "currency", default: "USD", null: false
    t.date "valued_on", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_manual_assets_on_user_id"
  end

  create_table "plaid_items", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "institution_id", null: false
    t.string "plaid_item_id", null: false
    t.text "access_token", null: false
    t.string "cursor"
    t.string "status", default: "active", null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "sync_requested_at"
    t.string "sync_request_token"
    t.index ["institution_id"], name: "index_plaid_items_on_institution_id"
    t.index ["plaid_item_id"], name: "index_plaid_items_on_plaid_item_id", unique: true
    t.index ["user_id"], name: "index_plaid_items_on_user_id"
  end

  create_table "recurring_dismissals", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "detection_key", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "detection_key"], name: "index_recurring_dismissals_on_user_id_and_detection_key", unique: true
    t.index ["user_id"], name: "index_recurring_dismissals_on_user_id"
  end

  create_table "recurring_items", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "account_id"
    t.string "name", null: false
    t.decimal "amount", precision: 14, scale: 4, null: false
    t.string "currency", default: "USD", null: false
    t.string "direction", default: "expense", null: false
    t.string "frequency", default: "monthly", null: false
    t.date "next_on", null: false
    t.boolean "month_end", default: false, null: false
    t.string "status", default: "active", null: false
    t.string "merchant_key"
    t.string "source_account_name"
    t.string "detection_key"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_recurring_items_on_account_id"
    t.index ["user_id", "detection_key"], name: "index_recurring_items_on_user_id_and_detection_key", unique: true
    t.index ["user_id"], name: "index_recurring_items_on_user_id"
    t.check_constraint "amount > 0::numeric", name: "recurring_amount_positive"
  end

  create_table "transaction_rules", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "category_id"
    t.string "match_text"
    t.string "kind", default: "regular", null: false
    t.string "tags", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "merchant_key"
    t.bigint "account_id"
    t.string "source_account_name"
    t.string "description_operator", default: "contains", null: false
    t.datetime "effective_from"
    t.index ["account_id"], name: "index_transaction_rules_on_account_id"
    t.index ["category_id"], name: "index_transaction_rules_on_category_id"
    t.index ["user_id", "merchant_key"], name: "index_transaction_rules_on_user_id_and_merchant_key", unique: true, where: "(merchant_key IS NOT NULL)"
    t.index ["user_id"], name: "index_transaction_rules_on_user_id"
  end

  create_table "transactions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "account_id"
    t.bigint "plaid_item_id"
    t.bigint "category_id"
    t.string "plaid_transaction_id"
    t.string "source", default: "plaid", null: false
    t.string "source_transaction_id"
    t.boolean "pending", default: false, null: false
    t.decimal "amount", precision: 19, scale: 4, null: false
    t.string "iso_currency_code"
    t.date "date", null: false
    t.date "authorized_date"
    t.string "name", null: false
    t.string "merchant_name"
    t.string "merchant_entity_id"
    t.string "payment_channel"
    t.string "pending_transaction_id"
    t.string "original_description"
    t.text "notes"
    t.jsonb "raw_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source_account_name"
    t.string "tags", default: "", null: false
    t.boolean "hidden", default: false, null: false
    t.boolean "duplicate", default: false, null: false
    t.boolean "transfer", default: false, null: false
    t.boolean "card_payment", default: false, null: false
    t.boolean "is_split", default: false, null: false
    t.bigint "parent_id"
    t.boolean "split_needs_review", default: false, null: false
    t.boolean "classification_override", default: false, null: false
    t.string "classification_origin"
    t.string "classification_reason"
    t.string "suggested_classification"
    t.string "suggestion_reason"
    t.bigint "matched_transaction_id"
    t.boolean "category_locked", default: false, null: false
    t.string "category_origin"
    t.string "category_reason"
    t.string "category_suggestion_reason"
    t.bigint "suggested_category_id"
    t.string "expense_type"
    t.index ["account_id", "date"], name: "index_transactions_on_account_id_and_date"
    t.index ["account_id"], name: "index_transactions_on_account_id"
    t.index ["category_id"], name: "index_transactions_on_category_id"
    t.index ["matched_transaction_id"], name: "index_transactions_on_matched_transaction_id"
    t.index ["parent_id"], name: "index_transactions_on_parent_id"
    t.index ["plaid_item_id"], name: "index_transactions_on_plaid_item_id"
    t.index ["suggested_category_id"], name: "index_transactions_on_suggested_category_id"
    t.index ["user_id", "plaid_transaction_id"], name: "index_transactions_on_user_id_and_plaid_transaction_id", unique: true, where: "(plaid_transaction_id IS NOT NULL)"
    t.index ["user_id", "source", "source_transaction_id"], name: "idx_on_user_id_source_source_transaction_id_9233d84c22", unique: true, where: "(source_transaction_id IS NOT NULL)"
    t.index ["user_id"], name: "index_transactions_on_user_id"
    t.check_constraint "expense_type IS NULL OR (expense_type::text = ANY (ARRAY['fixed'::character varying::text, 'variable'::character varying::text, 'unclassified'::character varying::text]))", name: "valid_transaction_expense_type"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "session_token", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["session_token"], name: "index_users_on_session_token", unique: true
  end

  add_foreign_key "accounts", "plaid_items"
  add_foreign_key "accounts", "users"
  add_foreign_key "asset_valuations", "manual_assets"
  add_foreign_key "balance_snapshots", "accounts"
  add_foreign_key "balance_snapshots", "users"
  add_foreign_key "budgets", "categories"
  add_foreign_key "budgets", "users"
  add_foreign_key "categories", "categories", column: "parent_id"
  add_foreign_key "categories", "users"
  add_foreign_key "category_expense_types", "categories", on_delete: :cascade
  add_foreign_key "category_expense_types", "users"
  add_foreign_key "import_batches", "users"
  add_foreign_key "import_profiles", "users"
  add_foreign_key "manual_assets", "users"
  add_foreign_key "plaid_items", "institutions"
  add_foreign_key "plaid_items", "users"
  add_foreign_key "recurring_dismissals", "users"
  add_foreign_key "recurring_items", "accounts", on_delete: :nullify
  add_foreign_key "recurring_items", "users"
  add_foreign_key "transaction_rules", "accounts", on_delete: :cascade
  add_foreign_key "transaction_rules", "categories"
  add_foreign_key "transaction_rules", "users"
  add_foreign_key "transactions", "accounts"
  add_foreign_key "transactions", "categories"
  add_foreign_key "transactions", "categories", column: "suggested_category_id", on_delete: :nullify
  add_foreign_key "transactions", "plaid_items"
  add_foreign_key "transactions", "transactions", column: "matched_transaction_id", on_delete: :nullify
  add_foreign_key "transactions", "transactions", column: "parent_id"
  add_foreign_key "transactions", "users"
end
