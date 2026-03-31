-- +goose Up
-- +goose StatementBegin

-- posts multiple transactions in a single atomic call.
-- if any transaction fails validation, the entire batch rolls back.
-- input: jsonb array of objects with keys: debit, credit, amount, date (optional), description (optional)
create function ledger.post_transactions(
    p_ledger_uuid text,
    p_transactions jsonb
) returns text[] as $$
declare
    v_ledger_id bigint;
    v_entry jsonb;
    v_uuid text;
    v_uuids text[] := '{}';
    v_debit text;
    v_credit text;
    v_amount bigint;
    v_date date;
    v_description text;
begin
    -- validate ledger once
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    -- validate input is an array
    if jsonb_typeof(p_transactions) != 'array' then
        raise exception 'Transactions must be a JSON array';
    end if;

    if jsonb_array_length(p_transactions) = 0 then
        return v_uuids;
    end if;

    -- process each transaction
    for v_entry in select * from jsonb_array_elements(p_transactions)
    loop
        -- extract and validate required fields
        v_debit := v_entry->>'debit';
        v_credit := v_entry->>'credit';
        v_amount := (v_entry->>'amount')::bigint;

        if v_debit is null then
            raise exception 'Missing "debit" field in transaction entry';
        end if;

        if v_credit is null then
            raise exception 'Missing "credit" field in transaction entry';
        end if;

        if v_amount is null then
            raise exception 'Missing "amount" field in transaction entry';
        end if;

        -- optional fields
        v_date := coalesce((v_entry->>'date')::date, current_date);
        v_description := v_entry->>'description';

        -- post via ledger.post_transaction (handles all validation, counters, balances)
        select ledger.post_transaction(
            p_ledger_uuid, v_debit, v_credit, v_amount, v_date, v_description
        ) into v_uuid;

        v_uuids := array_append(v_uuids, v_uuid);
    end loop;

    return v_uuids;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists ledger.post_transactions(text, jsonb);

-- +goose StatementEnd
