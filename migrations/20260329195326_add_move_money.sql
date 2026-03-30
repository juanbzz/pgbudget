-- +goose Up
-- +goose StatementBegin

-- moves money between categories within a budget.
-- internally: debit source category (decrease), credit destination category (increase).
create function utils.move_between_categories(
    p_ledger_uuid text,
    p_from_category_uuid text,
    p_to_category_uuid text,
    p_amount bigint,
    p_description text,
    p_date date,
    p_user_data text default utils.get_user()
) returns int as $$
declare
    v_ledger_id bigint;
    v_from_id bigint;
    v_to_id bigint;
    v_transaction_id int;
begin
    -- validate amount
    if p_amount <= 0 then
        raise exception 'Move amount must be positive: %', p_amount;
    end if;

    -- find ledger and validate ownership
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;

    if v_ledger_id is null then
        raise exception 'Budget with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- find source category
    select a.id into v_from_id
    from data.accounts a
    where a.uuid = p_from_category_uuid
      and a.ledger_id = v_ledger_id
      and a.user_data = p_user_data
      and a.type = 'equity';

    if v_from_id is null then
        raise exception 'Source category with UUID % not found in budget for current user', p_from_category_uuid;
    end if;

    -- find destination category
    select a.id into v_to_id
    from data.accounts a
    where a.uuid = p_to_category_uuid
      and a.ledger_id = v_ledger_id
      and a.user_data = p_user_data
      and a.type = 'equity';

    if v_to_id is null then
        raise exception 'Destination category with UUID % not found in budget for current user', p_to_category_uuid;
    end if;

    -- reject same source and destination
    if v_from_id = v_to_id then
        raise exception 'Source and destination categories must be different';
    end if;

    -- insert the transaction: debit source (decrease), credit destination (increase)
    insert into data.transactions (
        ledger_id, date, description, amount,
        debit_account_id, credit_account_id, user_data
    ) values (
        v_ledger_id, p_date, p_description, p_amount,
        v_from_id, v_to_id, p_user_data
    ) returning id into v_transaction_id;

    return v_transaction_id;
end;
$$ language plpgsql security definer;

-- public api function
create function api.move_money(
    p_budget_uuid text,
    p_from_category_uuid text,
    p_to_category_uuid text,
    p_amount bigint,
    p_description text default null,
    p_date date default current_date
) returns text as $$
declare
    v_transaction_id int;
    v_transaction_uuid text;
begin
    select utils.move_between_categories(
        p_budget_uuid,
        p_from_category_uuid,
        p_to_category_uuid,
        p_amount,
        p_description,
        p_date
    ) into v_transaction_id;

    select uuid into v_transaction_uuid
    from data.transactions
    where id = v_transaction_id;

    return v_transaction_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists api.move_money(text, text, text, bigint, text, date);
drop function if exists utils.move_between_categories(text, text, text, bigint, text, date, text);

-- +goose StatementEnd
