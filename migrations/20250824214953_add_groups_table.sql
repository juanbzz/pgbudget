-- +goose Up
-- +goose StatementBegin

-- creates the groups table to organize categories into logical groups.
create table data.groups
(
    id          bigint generated always as identity primary key,
    uuid        text        not null default utils.nanoid(8),

    created_at  timestamptz not null default current_timestamp,
    updated_at  timestamptz not null default current_timestamp,

    name        text        not null,
    description text,
    sort_order  integer     not null default 0,
    metadata    jsonb,
    user_data   text        not null default utils.get_user(),

    -- links the group to a ledger. groups are deleted if the parent ledger is deleted.
    ledger_id   bigint      not null references data.ledgers (id) on delete cascade,

    -- constraints
    constraint groups_uuid_unique unique (uuid),
    constraint groups_name_ledger_unique unique (name, ledger_id, user_data),
    constraint groups_name_length_check check (char_length(name) <= 255),
    constraint groups_user_data_length_check check (char_length(user_data) <= 255),
    constraint groups_description_length_check check (char_length(description) <= 255)
);

-- enables row level security (rls) on the data.groups table.
alter table data.groups
    enable row level security;

-- creates an rls policy on data.groups to ensure users can only access and modify their own groups.
create policy groups_policy on data.groups
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

comment on policy groups_policy on data.groups is 'Ensures that users can only access and modify their own groups based on the user_data column.';

-- creates an index on ledger_id for efficient queries.
create index groups_ledger_id_idx on data.groups (ledger_id);

-- creates an index on sort_order for efficient ordering.
create index groups_sort_order_idx on data.groups (sort_order);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop policy if exists groups_policy on data.groups;

drop table if exists data.groups;

-- +goose StatementEnd
