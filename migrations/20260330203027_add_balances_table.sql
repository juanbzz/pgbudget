-- +goose Up
-- +goose StatementBegin

-- append-only balance history table.
-- each row records an account's cumulative debit/credit totals after a specific transaction.
-- written by ledger.post_transaction(), not by a trigger.
create table data.balances (
    id             bigint generated always as identity primary key,
    account_id     bigint not null references data.accounts(id),
    transaction_id bigint not null references data.transactions(id),
    debits_total   bigint not null,
    credits_total  bigint not null,
    created_at     timestamptz not null default current_timestamp,
    user_data      text not null default utils.get_user(),

    constraint balances_account_transaction_unique unique (account_id, transaction_id, user_data)
);

-- fast lookup: latest balance per account
create index idx_balances_account_transaction on data.balances(account_id, transaction_id desc);

-- RLS isolation
create index idx_balances_user_data on data.balances(user_data);

-- enable RLS
alter table data.balances enable row level security;

create policy balances_policy on data.balances
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop policy if exists balances_policy on data.balances;
drop table if exists data.balances;

-- +goose StatementEnd
