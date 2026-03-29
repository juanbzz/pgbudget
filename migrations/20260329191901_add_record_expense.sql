-- +goose Up
-- +goose StatementBegin

-- records an expense from a bank or credit card account.
-- category is optional — defaults to Unassigned if not provided.
create function api.record_expense(
    p_budget_uuid text,
    p_account_uuid text,
    p_amount bigint,
    p_category_uuid text default null,
    p_description text default null,
    p_date date default current_date
) returns text as $$
declare
    v_transaction_id int;
    v_transaction_uuid text;
begin
    -- call utils.add_transaction with type='outflow'
    -- if category is null, utils.add_transaction defaults to Unassigned
    select utils.add_transaction(
        p_budget_uuid,
        p_date::timestamptz,
        p_description,
        'outflow',
        p_amount,
        p_account_uuid,
        p_category_uuid
    ) into v_transaction_id;

    -- get the uuid of the created transaction
    select uuid into v_transaction_uuid
    from data.transactions
    where id = v_transaction_id;

    return v_transaction_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists api.record_expense(text, text, bigint, text, text, date);

-- +goose StatementEnd
