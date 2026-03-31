-- +goose Up
-- +goose StatementBegin

-- returns the current balance for an account.
-- reads directly from data.accounts counters — no table scan, no computation.
-- asset_like: debits - credits (debits increase balance)
-- liability_like/equity: credits - debits (credits increase balance)
create function ledger.get_balance(
    p_account_uuid text
) returns bigint as $$
declare
    v_account data.accounts;
begin
    select * into v_account
    from data.accounts
    where uuid = p_account_uuid and user_data = utils.get_user();

    if v_account.id is null then
        raise exception 'Account not found: %', p_account_uuid;
    end if;

    if v_account.internal_type = 'asset_like' then
        return v_account.debits_total - v_account.credits_total;
    else
        return v_account.credits_total - v_account.debits_total;
    end if;
end;
$$ language plpgsql stable security definer;

-- returns all account balances for a ledger.
create function ledger.get_balances(
    p_ledger_uuid text
) returns table(
    account_uuid text,
    account_name text,
    account_type text,
    balance bigint
) as $$
declare
    v_ledger_id bigint;
begin
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    return query
    select
        a.uuid::text,
        a.name,
        a.type,
        case when a.internal_type = 'asset_like'
            then a.debits_total - a.credits_total
            else a.credits_total - a.debits_total
        end as balance
    from data.accounts a
    where a.ledger_id = v_ledger_id
      and a.user_data = utils.get_user()
    order by a.type, a.name;
end;
$$ language plpgsql stable security definer;

-- returns transaction history for an account with running balances.
-- joins data.transactions with data.balances for the running balance after each transaction.
create function ledger.get_history(
    p_account_uuid text
) returns table(
    transaction_uuid text,
    date date,
    description text,
    counterparty text,
    amount bigint,
    direction text,
    running_balance bigint
) as $$
declare
    v_account_id bigint;
    v_internal_type text;
begin
    select a.id, a.internal_type
    into v_account_id, v_internal_type
    from data.accounts a
    where a.uuid = p_account_uuid and a.user_data = utils.get_user();

    if v_account_id is null then
        raise exception 'Account not found: %', p_account_uuid;
    end if;

    return query
    select
        t.uuid::text as transaction_uuid,
        t.date,
        t.description,
        -- the other account in this transaction
        case
            when t.debit_account_id = v_account_id then
                (select name from data.accounts where id = t.credit_account_id)
            else
                (select name from data.accounts where id = t.debit_account_id)
        end as counterparty,
        t.amount,
        -- direction relative to this account
        case
            when t.debit_account_id = v_account_id then 'debit'
            else 'credit'
        end as direction,
        -- running balance from data.balances
        coalesce(
            case when v_internal_type = 'asset_like'
                then b.debits_total - b.credits_total
                else b.credits_total - b.debits_total
            end,
            0
        ) as running_balance
    from
        data.transactions t
        left join data.balances b on (
            b.transaction_id = t.id
            and b.account_id = v_account_id
            and b.user_data = utils.get_user()
        )
    where
        (t.debit_account_id = v_account_id or t.credit_account_id = v_account_id)
        and t.deleted_at is null
    order by
        t.date desc,
        t.created_at desc;
end;
$$ language plpgsql stable security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists ledger.get_history(text);
drop function if exists ledger.get_balances(text);
drop function if exists ledger.get_balance(text);

-- +goose StatementEnd
