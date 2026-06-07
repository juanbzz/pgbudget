-- +goose Up
-- +goose StatementBegin

-- add a 16-bit code column to accounts and transactions for app-defined
-- categorization. the engine stores and indexes it but assigns no meaning.
alter table data.accounts     add column code smallint not null default 0;
alter table data.transactions add column code smallint not null default 0;

-- btree indexes for filtering by code
create index idx_accounts_code     on data.accounts(code);
create index idx_transactions_code on data.transactions(code);

-- extend ledger.create_account with an optional p_code parameter
drop function if exists ledger.create_account(text, text, text, boolean, boolean);

create function ledger.create_account(
    p_ledger_uuid text,
    p_name text,
    p_description text default null,
    p_debits_must_not_exceed_credits boolean default false,
    p_credits_must_not_exceed_debits boolean default false,
    p_code smallint default 0
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

    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    insert into data.accounts (
        name, description, ledger_id, user_data,
        debits_must_not_exceed_credits, credits_must_not_exceed_debits,
        code
    ) values (
        v_name, p_description, v_ledger_id, utils.get_user(),
        p_debits_must_not_exceed_credits, p_credits_must_not_exceed_debits,
        p_code
    ) returning uuid into v_account_uuid;

    return v_account_uuid;
end;
$$ language plpgsql security definer;

-- extend ledger.post_transaction with an optional p_code parameter
drop function if exists ledger.post_transaction(text, text, text, bigint, date, text, text);

create function ledger.post_transaction(
    p_ledger_uuid text,
    p_debit_account_uuid text,
    p_credit_account_uuid text,
    p_amount bigint,
    p_date date default current_date,
    p_description text default null,
    p_idempotency_key text default null,
    p_code smallint default 0
) returns text as $$
declare
    v_ledger_id bigint;
    v_debit data.accounts;
    v_credit data.accounts;
    v_txn_id bigint;
    v_txn_uuid text;
    v_user_data text := utils.get_user();
    v_needs_check boolean;
    v_existing_uuid text;
begin
    -- idempotency check
    if p_idempotency_key is not null then
        select uuid into v_existing_uuid
        from data.transactions
        where idempotency_key = p_idempotency_key and user_data = v_user_data;

        if v_existing_uuid is not null then
            return v_existing_uuid;
        end if;
    end if;

    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive: %', p_amount;
    end if;

    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = v_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    select * into v_debit
    from data.accounts
    where uuid = p_debit_account_uuid and ledger_id = v_ledger_id and user_data = v_user_data;

    if v_debit.id is null then
        raise exception 'Debit account not found: %', p_debit_account_uuid;
    end if;

    if v_debit.is_closed then
        raise exception 'Account % is closed', p_debit_account_uuid;
    end if;

    select * into v_credit
    from data.accounts
    where uuid = p_credit_account_uuid and ledger_id = v_ledger_id and user_data = v_user_data;

    if v_credit.id is null then
        raise exception 'Credit account not found: %', p_credit_account_uuid;
    end if;

    if v_credit.is_closed then
        raise exception 'Account % is closed', p_credit_account_uuid;
    end if;

    if v_debit.id = v_credit.id then
        raise exception 'Debit and credit accounts must be different';
    end if;

    begin
        insert into data.transactions (
            ledger_id, debit_account_id, credit_account_id,
            amount, date, description, user_data, idempotency_key, code
        ) values (
            v_ledger_id, v_debit.id, v_credit.id,
            p_amount, p_date, p_description, v_user_data, p_idempotency_key, p_code
        ) returning id, uuid into v_txn_id, v_txn_uuid;
    exception when unique_violation then
        if p_idempotency_key is not null then
            select uuid into v_existing_uuid
            from data.transactions
            where idempotency_key = p_idempotency_key and user_data = v_user_data;
            if v_existing_uuid is not null then
                return v_existing_uuid;
            end if;
        end if;
        raise;
    end;

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

-- extend ledger.get_accounts to return the code column
drop function if exists ledger.get_accounts(text, boolean);

create function ledger.get_accounts(
    p_ledger_uuid text,
    p_include_internal boolean default false
) returns table(
    account_uuid text,
    account_name text,
    description text,
    visibility text,
    code smallint,
    debits_must_not_exceed_credits boolean,
    credits_must_not_exceed_debits boolean,
    is_closed boolean,
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
        a.description,
        a.visibility,
        a.code,
        a.debits_must_not_exceed_credits,
        a.credits_must_not_exceed_debits,
        a.is_closed,
        a.created_at
    from data.accounts a
    where a.ledger_id = v_ledger_id
      and a.user_data = utils.get_user()
      and (p_include_internal or a.visibility = 'standard')
    order by a.name;
end;
$$ language plpgsql stable security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
select 'down migration not supported — code column additions and function signature changes';
-- +goose StatementEnd
