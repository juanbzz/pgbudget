-- +goose Up
-- +goose StatementBegin

create schema if not exists ledger;

-- creates a new ledger. generic — no default accounts, no budgeting concepts.
create function ledger.create_ledger(
    p_name text,
    p_description text default null
) returns text as $$
declare
    v_name text;
    v_ledger_uuid text;
begin
    v_name := trim(p_name);
    if v_name is null or v_name = '' then
        raise exception 'Ledger name cannot be empty';
    end if;

    insert into data.ledgers (name, description)
    values (v_name, p_description)
    returning uuid into v_ledger_uuid;

    return v_ledger_uuid;
end;
$$ language plpgsql security definer;

-- creates an account in a ledger. type must be asset, liability, or equity.
create function ledger.create_account(
    p_ledger_uuid text,
    p_name text,
    p_type text,
    p_description text default null
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

    insert into data.accounts (name, type, description, ledger_id, user_data)
    values (v_name, p_type, p_description, v_ledger_id, utils.get_user())
    returning uuid into v_account_uuid;

    return v_account_uuid;
end;
$$ language plpgsql security definer;

-- the core double-entry primitive.
-- inserts a transaction, updates account counters atomically, appends balance history.
-- no trigger. this function owns the entire write path.
create function ledger.post_transaction(
    p_ledger_uuid text,
    p_debit_account_uuid text,
    p_credit_account_uuid text,
    p_amount bigint,
    p_date date default current_date,
    p_description text default null
) returns text as $$
declare
    v_ledger_id bigint;
    v_debit_id bigint;
    v_credit_id bigint;
    v_txn_id bigint;
    v_txn_uuid text;
    v_user_data text := utils.get_user();
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

    -- validate debit account
    select id into v_debit_id
    from data.accounts
    where uuid = p_debit_account_uuid and ledger_id = v_ledger_id and user_data = v_user_data;

    if v_debit_id is null then
        raise exception 'Debit account not found: %', p_debit_account_uuid;
    end if;

    -- validate credit account
    select id into v_credit_id
    from data.accounts
    where uuid = p_credit_account_uuid and ledger_id = v_ledger_id and user_data = v_user_data;

    if v_credit_id is null then
        raise exception 'Credit account not found: %', p_credit_account_uuid;
    end if;

    -- reject same account
    if v_debit_id = v_credit_id then
        raise exception 'Debit and credit accounts must be different';
    end if;

    -- 1. INSERT transaction
    insert into data.transactions (
        ledger_id, debit_account_id, credit_account_id,
        amount, date, description, user_data
    ) values (
        v_ledger_id, v_debit_id, v_credit_id,
        p_amount, p_date, p_description, v_user_data
    ) returning id, uuid into v_txn_id, v_txn_uuid;

    -- 2. UPDATE account counters (atomic, concurrent-safe)
    update data.accounts set debits_total = debits_total + p_amount
    where id = v_debit_id;

    update data.accounts set credits_total = credits_total + p_amount
    where id = v_credit_id;

    -- 3. INSERT balance history (append-only, reads updated counters)
    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select v_debit_id, v_txn_id, debits_total, credits_total, v_user_data
    from data.accounts where id = v_debit_id;

    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select v_credit_id, v_txn_id, debits_total, credits_total, v_user_data
    from data.accounts where id = v_credit_id;

    return v_txn_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists ledger.post_transaction(text, text, text, bigint, date, text);
drop function if exists ledger.create_account(text, text, text, text);
drop function if exists ledger.create_ledger(text, text);
drop schema if exists ledger;

-- +goose StatementEnd
