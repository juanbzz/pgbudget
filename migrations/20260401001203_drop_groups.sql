-- +goose Up
-- +goose StatementBegin

-- drop group_id column from accounts (also drops the FK and index)
drop index if exists data.accounts_group_id_idx;
alter table data.accounts drop column if exists group_id;

-- drop the groups table
drop policy if exists groups_policy on data.groups;
drop table if exists data.groups;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
select 'down migration not supported — groups table must be recreated from earlier migrations';
-- +goose StatementEnd
