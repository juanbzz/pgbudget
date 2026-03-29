-- +goose Up
-- +goose StatementBegin

-- assigns money from "available to budget" (Income) to a category.
-- this is the "give every dollar a job" operation.
create function api.budget_money(
    p_budget_uuid text,
    p_category_uuid text,
    p_amount bigint,
    p_description text default null,
    p_date date default current_date
) returns text as $$
declare
    v_transaction_uuid text;
begin
    -- call utils.assign_to_category which handles:
    -- - looking up the Income account
    -- - creating the transaction (Debit Income, Credit Category)
    -- - validation (amount, budget ownership, category existence)
    select r_uuid into v_transaction_uuid
    from utils.assign_to_category(
        p_budget_uuid,
        p_date::timestamptz,
        p_description,
        p_amount,
        p_category_uuid
    );

    return v_transaction_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists api.budget_money(text, text, bigint, text, date);

-- +goose StatementEnd
