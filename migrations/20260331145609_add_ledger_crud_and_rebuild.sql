-- +goose Up
-- +goose StatementBegin

-- deletes a ledger and all related data.
-- temporarily disables the special account deletion trigger so Income/Off-budget/Unassigned
-- can be deleted as part of the ledger teardown.
create function ledger.delete_ledger(
    p_ledger_uuid text
) returns void as $$
declare
    v_ledger_id bigint;
begin
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    -- clean up pending holds for accounts in this ledger
    delete from data.pending
    where account_id in (select id from data.accounts where ledger_id = v_ledger_id);

    -- clean up balance history for accounts in this ledger
    delete from data.balances
    where account_id in (select id from data.accounts where ledger_id = v_ledger_id);

    -- disable special account protection trigger for this delete
    alter table data.accounts disable trigger trigger_prevent_special_account_deletion;

    -- CASCADE on data.ledgers handles: accounts, transactions, transaction_log, groups
    delete from data.ledgers where id = v_ledger_id;

    -- re-enable the trigger
    alter table data.accounts enable trigger trigger_prevent_special_account_deletion;
end;
$$ language plpgsql security definer;

-- lists accounts in a ledger (without balance computation)
create function ledger.get_accounts(
    p_ledger_uuid text
) returns table(
    account_uuid text,
    account_name text,
    account_type text,
    description text,
    debits_must_not_exceed_credits boolean,
    credits_must_not_exceed_debits boolean,
    created_at timestamptz
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
        a.description,
        a.debits_must_not_exceed_credits,
        a.credits_must_not_exceed_debits,
        a.created_at
    from data.accounts a
    where a.ledger_id = v_ledger_id
      and a.user_data = utils.get_user()
    order by a.type, a.name;
end;
$$ language plpgsql stable security definer;

-- rebuilds debits_total/credits_total on data.accounts and data.balances
-- from data.transactions. safety net for data repair.
create function ledger.rebuild_balances(
    p_ledger_uuid text
) returns void as $$
declare
    v_ledger_id bigint;
    v_account record;
    v_txn record;
    v_running_debits bigint;
    v_running_credits bigint;
begin
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    -- reset all account counters in this ledger
    update data.accounts
    set debits_total = 0, credits_total = 0
    where ledger_id = v_ledger_id and user_data = utils.get_user();

    -- delete all balance history for this ledger
    delete from data.balances
    where account_id in (select id from data.accounts where ledger_id = v_ledger_id)
      and user_data = utils.get_user();

    -- recompute from posted transactions in chronological order
    for v_txn in
        select id, debit_account_id, credit_account_id, amount
        from data.transactions
        where ledger_id = v_ledger_id
          and user_data = utils.get_user()
          and status = 'posted'
        order by id
    loop
        -- update debit account counter
        update data.accounts
        set debits_total = debits_total + v_txn.amount
        where id = v_txn.debit_account_id;

        -- update credit account counter
        update data.accounts
        set credits_total = credits_total + v_txn.amount
        where id = v_txn.credit_account_id;

        -- append balance history for debit account
        insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
        select v_txn.debit_account_id, v_txn.id, debits_total, credits_total, utils.get_user()
        from data.accounts where id = v_txn.debit_account_id;

        -- append balance history for credit account
        insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
        select v_txn.credit_account_id, v_txn.id, debits_total, credits_total, utils.get_user()
        from data.accounts where id = v_txn.credit_account_id;
    end loop;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists ledger.rebuild_balances(text);
drop function if exists ledger.get_accounts(text);
drop function if exists ledger.delete_ledger(text);

-- +goose StatementEnd
