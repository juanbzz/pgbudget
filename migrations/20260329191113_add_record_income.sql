-- +goose Up
-- +goose StatementBegin

-- records income into a bank or cash account.
-- the money goes to the Income account (available to budget) automatically.
-- the caller doesn't need to know about the Income account.
create function api.record_income(
    p_budget_uuid text,
    p_account_uuid text,
    p_amount bigint,
    p_description text,
    p_date date default current_date
) returns text as $$
declare
    v_ledger_id bigint;
    v_income_uuid text;
    v_transaction_id int;
    v_transaction_uuid text;
begin
    -- find the budget and validate ownership
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_budget_uuid and l.user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Budget with UUID % not found for current user', p_budget_uuid;
    end if;

    -- look up the Income account for this budget
    select a.uuid into v_income_uuid
    from data.accounts a
    where a.ledger_id = v_ledger_id
      and a.user_data = utils.get_user()
      and a.name = 'Income'
      and a.type = 'equity';

    if v_income_uuid is null then
        raise exception 'Income account not found for budget %', p_budget_uuid;
    end if;

    -- call utils.add_transaction with type='inflow' and Income as the category
    select utils.add_transaction(
        p_budget_uuid,
        p_date::timestamptz,
        p_description,
        'inflow',
        p_amount,
        p_account_uuid,
        v_income_uuid
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

drop function if exists api.record_income(text, text, bigint, text, date);

-- +goose StatementEnd
