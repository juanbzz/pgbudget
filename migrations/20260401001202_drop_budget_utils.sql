-- +goose Up
-- +goose StatementBegin

-- budget trigger on ledger creation (auto-creates Income, Off-budget, Unassigned)
drop trigger if exists trigger_create_default_ledger_accounts on data.ledgers;
drop function if exists utils.create_default_ledger_accounts();

-- special accounts unique index
drop index if exists data.unique_special_accounts_per_ledger;

-- category utils
drop function if exists utils.add_category(text, text, text);
drop function if exists utils.add_categories(text, text[], text);
drop function if exists utils.find_category(text, text, text);

-- budget-specific utils
drop function if exists utils.move_between_categories(text, text, text, bigint, text, date, text);
drop function if exists utils.get_budget_status(text, text, date, date);
drop function if exists utils.get_budget_status(text, text);
drop function if exists utils.get_income_total(text, text, date, date);

-- old transaction path (used by former api.record_income/expense)
drop function if exists utils.add_transaction cascade;
drop function if exists utils.assign_to_category cascade;

-- old balance utils (replaced by ledger.get_balance / counters)
drop function if exists utils.get_account_balance(bigint, bigint);
drop function if exists utils.get_account_balance(text, text);
drop function if exists utils.get_account_transactions(text, text);
drop function if exists utils.get_account_balance_from_snapshots(text);
drop function if exists utils.get_account_balance_history(text, int);
drop function if exists utils.get_ledger_current_balances(text);
drop function if exists utils.rebuild_ledger_balance_snapshots(text);
drop function if exists utils.get_account_current_balance(bigint, bigint);

-- old balance snapshot system
drop function if exists utils.create_balance_snapshots() cascade;
drop function if exists utils.rebuild_account_balance_snapshots(text);
drop function if exists utils.transaction_balance_snapshot_fn() cascade;

-- old correction/deletion utils (replaced by ledger.void/correct)
drop function if exists utils.correct_transaction cascade;
drop function if exists utils.delete_transaction cascade;

-- enhanced error handling (only used by old budget utils)
drop function if exists utils.handle_constraint_violation(text, text, text);
drop function if exists utils.validate_transaction_data(bigint, timestamptz, text);
drop function if exists utils.validate_transaction_data(bigint, timestamptz);
drop function if exists utils.validate_input_data(text, text, text);

-- legacy view trigger functions (api views already dropped)
drop function if exists utils.accounts_insert_single_fn() cascade;
drop function if exists utils.accounts_update_single_fn() cascade;
drop function if exists utils.accounts_delete_single_fn() cascade;
drop function if exists utils.simple_transactions_insert_fn() cascade;
drop function if exists utils.simple_transactions_update_fn() cascade;
drop function if exists utils.simple_transactions_delete_fn() cascade;

-- special account protection (already dropped trigger, drop function)
drop function if exists utils.prevent_special_account_deletion();

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
select 'down migration not supported — budget utils must be recreated from earlier migrations';
-- +goose StatementEnd
