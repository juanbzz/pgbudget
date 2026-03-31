-- +goose Up
-- +goose StatementBegin

-- add per-account balance constraint flags.
-- when true, ledger.post_transaction() rejects transactions that would violate the constraint.
alter table data.accounts add column debits_must_not_exceed_credits boolean not null default false;
alter table data.accounts add column credits_must_not_exceed_debits boolean not null default false;

-- update ledger.create_account to accept constraint flags
drop function if exists ledger.create_account(text, text, text, text);

create function ledger.create_account(
    p_ledger_uuid text,
    p_name text,
    p_type text,
    p_description text default null,
    p_debits_must_not_exceed_credits boolean default false,
    p_credits_must_not_exceed_debits boolean default false
) returns text as $$
declare
    v_name text;
    v_ledger_id bigint;
    v_account_uuid text;
begin
    v_name := trim(p_name);
    if v_name is null or v_name = '' then
        raise exception 'Account name cannot be empty';
    end if;

    if p_type not in ('asset', 'liability', 'equity') then
        raise exception 'Invalid account type: %. Use asset, liability, or equity', p_type;
    end if;

    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    insert into data.accounts (
        name, type, description, ledger_id, user_data,
        debits_must_not_exceed_credits, credits_must_not_exceed_debits
    ) values (
        v_name, p_type, p_description, v_ledger_id, utils.get_user(),
        p_debits_must_not_exceed_credits, p_credits_must_not_exceed_debits
    ) returning uuid into v_account_uuid;

    return v_account_uuid;
end;
$$ language plpgsql security definer;

-- internal: fast path — no constraint checks, no conditional WHERE
create or replace function utils.post_transaction_fast(
    p_debit_id bigint,
    p_credit_id bigint,
    p_amount bigint,
    p_txn_id bigint,
    p_user_data text
) returns void as $$
begin
    -- unconditional counter updates
    update data.accounts set debits_total = debits_total + p_amount where id = p_debit_id;
    update data.accounts set credits_total = credits_total + p_amount where id = p_credit_id;

    -- append balance history
    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select p_debit_id, p_txn_id, debits_total, credits_total, p_user_data
    from data.accounts where id = p_debit_id;

    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select p_credit_id, p_txn_id, debits_total, credits_total, p_user_data
    from data.accounts where id = p_credit_id;
end;
$$ language plpgsql security definer;

-- internal: checked path — conditional UPDATE with constraint enforcement
create or replace function utils.post_transaction_checked(
    p_debit_id bigint,
    p_credit_id bigint,
    p_amount bigint,
    p_txn_id bigint,
    p_user_data text,
    p_debit_uuid text,
    p_credit_uuid text
) returns void as $$
declare
    v_updated boolean;
begin
    -- update debit account with constraint check if needed
    update data.accounts
    set debits_total = debits_total + p_amount
    where id = p_debit_id
      and (not debits_must_not_exceed_credits or debits_total + p_amount <= credits_total);

    if not found then
        raise exception 'Transaction rejected: would exceed credit balance on account %', p_debit_uuid;
    end if;

    -- update credit account with constraint check if needed
    update data.accounts
    set credits_total = credits_total + p_amount
    where id = p_credit_id
      and (not credits_must_not_exceed_debits or credits_total + p_amount <= debits_total);

    if not found then
        -- rollback the debit update (within same transaction, this will be rolled back anyway
        -- by the exception, but let's be explicit)
        raise exception 'Transaction rejected: would exceed debit balance on account %', p_credit_uuid;
    end if;

    -- append balance history
    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select p_debit_id, p_txn_id, debits_total, credits_total, p_user_data
    from data.accounts where id = p_debit_id;

    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select p_credit_id, p_txn_id, debits_total, credits_total, p_user_data
    from data.accounts where id = p_credit_id;
end;
$$ language plpgsql security definer;

-- update ledger.post_transaction to route to fast or checked path
create or replace function ledger.post_transaction(
    p_ledger_uuid text,
    p_debit_account_uuid text,
    p_credit_account_uuid text,
    p_amount bigint,
    p_date date default current_date,
    p_description text default null
) returns text as $$
declare
    v_ledger_id bigint;
    v_debit data.accounts;
    v_credit data.accounts;
    v_txn_id bigint;
    v_txn_uuid text;
    v_user_data text := utils.get_user();
    v_needs_check boolean;
begin
    -- validate amount
    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive: %', p_amount;
    end if;

    -- validate ledger
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = v_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    -- read both accounts (need full row for constraint flags)
    select * into v_debit
    from data.accounts
    where uuid = p_debit_account_uuid and ledger_id = v_ledger_id and user_data = v_user_data;

    if v_debit.id is null then
        raise exception 'Debit account not found: %', p_debit_account_uuid;
    end if;

    select * into v_credit
    from data.accounts
    where uuid = p_credit_account_uuid and ledger_id = v_ledger_id and user_data = v_user_data;

    if v_credit.id is null then
        raise exception 'Credit account not found: %', p_credit_account_uuid;
    end if;

    -- reject same account
    if v_debit.id = v_credit.id then
        raise exception 'Debit and credit accounts must be different';
    end if;

    -- 1. INSERT transaction
    insert into data.transactions (
        ledger_id, debit_account_id, credit_account_id,
        amount, date, description, user_data
    ) values (
        v_ledger_id, v_debit.id, v_credit.id,
        p_amount, p_date, p_description, v_user_data
    ) returning id, uuid into v_txn_id, v_txn_uuid;

    -- 2. route to fast or checked path
    v_needs_check := v_debit.debits_must_not_exceed_credits or v_credit.credits_must_not_exceed_debits;

    if v_needs_check then
        perform utils.post_transaction_checked(
            v_debit.id, v_credit.id, p_amount, v_txn_id, v_user_data,
            p_debit_account_uuid, p_credit_account_uuid
        );
    else
        perform utils.post_transaction_fast(
            v_debit.id, v_credit.id, p_amount, v_txn_id, v_user_data
        );
    end if;

    return v_txn_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- restore original ledger.post_transaction without constraint routing
-- (not practical to fully restore — use backup)
drop function if exists utils.post_transaction_checked(bigint, bigint, bigint, bigint, text, text, text);
drop function if exists utils.post_transaction_fast(bigint, bigint, bigint, bigint, text);

alter table data.accounts drop column if exists credits_must_not_exceed_debits;
alter table data.accounts drop column if exists debits_must_not_exceed_credits;

-- +goose StatementEnd
