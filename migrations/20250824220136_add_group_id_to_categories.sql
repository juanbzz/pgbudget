-- +goose Up
-- +goose StatementBegin

-- adds group_id column to accounts table to link category accounts to groups.
-- only applies to accounts with type = 'equity' (categories)
alter table data.accounts
    add column group_id bigint references data.groups (id) on delete set null;

-- creates an index on group_id for efficient queries.
create index accounts_group_id_idx on data.accounts (group_id);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop index if exists accounts_group_id_idx;

alter table data.accounts
    drop column if exists group_id;

-- +goose StatementEnd
