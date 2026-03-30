-- +goose Up
-- +goose StatementBegin

-- add cumulative debit/credit counters to accounts.
-- these are updated atomically by ledger.post_transaction() (no trigger).
-- current balance = debits_total - credits_total (asset_like)
--                 or credits_total - debits_total (liability_like/equity)
alter table data.accounts add column debits_total bigint not null default 0;
alter table data.accounts add column credits_total bigint not null default 0;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

alter table data.accounts drop column if exists credits_total;
alter table data.accounts drop column if exists debits_total;

-- +goose StatementEnd
