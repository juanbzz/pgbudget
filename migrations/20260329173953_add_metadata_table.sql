-- +goose Up
-- +goose StatementBegin

-- key-value config table for version tracking and internal settings.
-- this is infrastructure, not a domain entity, so it skips the standard
-- id/uuid/timestamps structure.
create table if not exists utils.metadata (
    key   text primary key,
    value text not null
);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop table if exists utils.metadata;

-- +goose StatementEnd
