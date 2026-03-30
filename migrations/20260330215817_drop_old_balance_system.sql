-- +goose Up
-- +goose StatementBegin

-- drop the balance snapshot trigger (transactions no longer auto-create snapshots)
drop trigger if exists transaction_balance_snapshot_tg on data.transactions;
drop function if exists utils.transaction_balance_snapshot_fn();

-- drop functions that write to balance_snapshots
drop function if exists utils.create_balance_snapshots(bigint);
drop function if exists utils.rebuild_account_balance_snapshots(bigint);

-- drop api/utils rebuild wrappers
drop function if exists api.rebuild_ledger_balance_snapshots(text);
drop function if exists utils.rebuild_ledger_balance_snapshots(text);

-- drop functions that read from balance_snapshots
drop function if exists utils.get_account_current_balance(bigint);
drop function if exists utils.get_account_balance_from_snapshots(text);
drop function if exists api.get_account_balance(text);
drop function if exists utils.get_account_balance_history(text, int);
drop function if exists api.get_account_balance_history(text, int);
drop function if exists utils.get_ledger_current_balances(text);
drop function if exists api.get_ledger_balances(text);

-- drop the old table
drop table if exists data.balance_snapshots;

-- replace utils.get_account_balance to read from data.accounts counters
-- instead of summing transactions on-demand.
-- keeps the same signature so budget status/totals functions don't break.
create or replace function utils.get_account_balance(
    p_ledger_id bigint,
    p_account_id bigint
) returns bigint as $$
declare
    v_balance bigint;
    v_internal_type text;
    v_account_ledger_id bigint;
begin
    select internal_type, ledger_id, debits_total, credits_total
    into v_internal_type, v_account_ledger_id, v_balance, v_balance
    from data.accounts
    where id = p_account_id;

    if v_internal_type is null then
        raise exception 'Account with ID % not found', p_account_id;
    end if;

    if v_account_ledger_id != p_ledger_id then
        raise exception 'account not found or does not belong to the specified ledger';
    end if;

    -- read balance from counters
    if v_internal_type = 'asset_like' then
        select debits_total - credits_total into v_balance
        from data.accounts where id = p_account_id;
    else
        select credits_total - debits_total into v_balance
        from data.accounts where id = p_account_id;
    end if;

    return coalesce(v_balance, 0);
end;
$$ language plpgsql stable security definer;

-- recreate api.get_account_balance reading from counters (temporary, until api schema is dropped)
create function api.get_account_balance(
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

-- recreate api.get_ledger_balances reading from counters (temporary)
create function api.get_ledger_balances(
    p_ledger_uuid text
) returns table(
    account_uuid text,
    account_name text,
    account_type text,
    current_balance bigint
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
        end as current_balance
    from data.accounts a
    where a.ledger_id = v_ledger_id
      and a.user_data = utils.get_user()
    order by a.type, a.name;
end;
$$ language plpgsql stable security definer;

-- update utils.get_account_transactions to not join balance_snapshots.
-- running_balance will be 0 until ledger.get_history() replaces this function.
create or replace function utils.get_account_transactions(
    p_account_uuid text,
    p_user_data text default utils.get_user()
)
returns table (
    date date,
    category text,
    description text,
    type text,
    amount bigint,
    running_balance bigint
) as $$
declare
    v_account_id bigint;
    v_internal_type text;
begin
    select a.id, a.internal_type
    into v_account_id, v_internal_type
    from data.accounts a
    where a.uuid = p_account_uuid and a.user_data = p_user_data;

    if v_account_id is null then
        raise exception 'Account with UUID % not found for current user', p_account_uuid;
    end if;

    return query
    select
        t.date,
        case
            when t.debit_account_id = v_account_id then
                (select name from data.accounts where id = t.credit_account_id)
            else
                (select name from data.accounts where id = t.debit_account_id)
        end as category,
        t.description,
        case
            when (v_internal_type = 'asset_like' and t.debit_account_id = v_account_id) or
                 (v_internal_type = 'liability_like' and t.credit_account_id = v_account_id)
            then 'inflow'
            else 'outflow'
        end as type,
        t.amount,
        -- join data.balances for running balance (uses new table)
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
            and b.user_data = p_user_data
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

-- this is a breaking migration — down would need to recreate the entire old balance system.
-- not practical. use a database backup if rollback is needed.
do $$ begin
    raise exception 'This migration cannot be rolled back. Restore from backup.';
end $$;

-- +goose StatementEnd
