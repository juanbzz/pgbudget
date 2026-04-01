-- +goose Up
-- +goose StatementBegin

-- the api schema contains only budget-specific and legacy functions.
-- no ledger function depends on it. drop it entirely.
drop schema if exists api cascade;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

create schema if not exists api;

-- +goose StatementEnd
