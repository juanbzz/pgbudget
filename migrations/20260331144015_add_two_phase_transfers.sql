-- +goose Up
-- +goose StatementBegin

-- add timeout column to transactions for pending transfers
alter table data.transactions add column timeout_at timestamptz;

-- expand status check to include voided and expired
alter table data.transactions drop constraint transactions_status_check;
alter table data.transactions add constraint transactions_status_check
    check (status in ('pending', 'posted', 'voided', 'expired'));

-- pending holds table — rows exist only while a hold is active.
-- deleted on commit, void, or timeout. no counters to drift.
create table data.pending (
    id             bigint generated always as identity primary key,
    account_id     bigint not null references data.accounts(id),
    transaction_id bigint not null references data.transactions(id) on delete cascade,
    amount         bigint not null,
    created_at     timestamptz not null default current_timestamp,
    timeout_at     timestamptz,
    user_data      text not null default utils.get_user(),

    constraint pending_account_transaction_unique unique (account_id, transaction_id, user_data)
);

create index idx_pending_account on data.pending(account_id);
create index idx_pending_timeout on data.pending(timeout_at) where timeout_at is not null;
create index idx_pending_user_data on data.pending(user_data);

alter table data.pending enable row level security;

create policy pending_policy on data.pending
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

-- reserves funds without settling. creates a pending transaction + hold rows.
-- posted counters are NOT updated. balance history is NOT written.
create function ledger.reserve(
    p_ledger_uuid text,
    p_debit_account_uuid text,
    p_credit_account_uuid text,
    p_amount bigint,
    p_timeout_seconds integer default 300,
    p_date date default current_date,
    p_description text default null,
    p_idempotency_key text default null
) returns text as $$
declare
    v_ledger_id bigint;
    v_debit data.accounts;
    v_credit data.accounts;
    v_txn_id bigint;
    v_txn_uuid text;
    v_user_data text := utils.get_user();
    v_timeout_at timestamptz;
    v_existing_uuid text;
    v_pending_debits bigint;
    v_pending_credits bigint;
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

    -- validate amount
    if p_amount <= 0 then
        raise exception 'Reserve amount must be positive: %', p_amount;
    end if;

    -- calculate timeout
    if p_timeout_seconds is not null and p_timeout_seconds > 0 then
        v_timeout_at := now() + (p_timeout_seconds || ' seconds')::interval;
    end if;

    -- validate ledger
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = v_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    -- read both accounts
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

    if v_debit.id = v_credit.id then
        raise exception 'Debit and credit accounts must be different';
    end if;

    -- check balance constraints (posted + pending + new amount)
    if v_debit.debits_must_not_exceed_credits then
        select coalesce(sum(amount), 0) into v_pending_debits
        from data.pending where account_id = v_debit.id;

        if (v_debit.debits_total + v_pending_debits + p_amount) > v_debit.credits_total then
            raise exception 'Reserve rejected: would exceed credit balance on account %', p_debit_account_uuid;
        end if;
    end if;

    if v_credit.credits_must_not_exceed_debits then
        select coalesce(sum(amount), 0) into v_pending_credits
        from data.pending where account_id = v_credit.id;

        if (v_credit.credits_total + v_pending_credits + p_amount) > v_credit.debits_total then
            raise exception 'Reserve rejected: would exceed debit balance on account %', p_credit_account_uuid;
        end if;
    end if;

    -- 1. INSERT pending transaction
    begin
        insert into data.transactions (
            ledger_id, debit_account_id, credit_account_id,
            amount, date, description, status, timeout_at, user_data, idempotency_key
        ) values (
            v_ledger_id, v_debit.id, v_credit.id,
            p_amount, p_date, p_description, 'pending', v_timeout_at, v_user_data, p_idempotency_key
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

    -- 2. INSERT pending hold rows (one per affected account)
    insert into data.pending (account_id, transaction_id, amount, timeout_at, user_data)
    values (v_debit.id, v_txn_id, p_amount, v_timeout_at, v_user_data);

    insert into data.pending (account_id, transaction_id, amount, timeout_at, user_data)
    values (v_credit.id, v_txn_id, p_amount, v_timeout_at, v_user_data);

    return v_txn_uuid;
end;
$$ language plpgsql security definer;

-- commits a pending transfer. moves from pending to posted.
-- supports partial commits — commit less than reserved, remainder released.
create function ledger.commit(
    p_transaction_uuid text,
    p_amount bigint default null
) returns text as $$
declare
    v_txn data.transactions;
    v_commit_amount bigint;
    v_user_data text := utils.get_user();
begin
    -- get the pending transaction
    select * into v_txn
    from data.transactions
    where uuid = p_transaction_uuid and user_data = v_user_data;

    if v_txn.id is null then
        raise exception 'Transaction not found: %', p_transaction_uuid;
    end if;

    if v_txn.status != 'pending' then
        raise exception 'Transaction % is not pending (status: %)', p_transaction_uuid, v_txn.status;
    end if;

    -- check if expired
    if v_txn.timeout_at is not null and v_txn.timeout_at < now() then
        raise exception 'Transaction % has expired', p_transaction_uuid;
    end if;

    -- determine commit amount
    v_commit_amount := coalesce(p_amount, v_txn.amount);

    if v_commit_amount <= 0 then
        raise exception 'Commit amount must be positive: %', v_commit_amount;
    end if;

    if v_commit_amount > v_txn.amount then
        raise exception 'Commit amount % exceeds reserved amount %', v_commit_amount, v_txn.amount;
    end if;

    -- 1. UPDATE transaction status and amount (partial commit adjusts amount)
    update data.transactions
    set status = 'posted', amount = v_commit_amount, timeout_at = null
    where id = v_txn.id;

    -- 2. DELETE pending hold rows
    delete from data.pending where transaction_id = v_txn.id;

    -- 3. UPDATE posted counters on accounts
    update data.accounts set debits_total = debits_total + v_commit_amount
    where id = v_txn.debit_account_id;

    update data.accounts set credits_total = credits_total + v_commit_amount
    where id = v_txn.credit_account_id;

    -- 4. INSERT balance history
    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select v_txn.debit_account_id, v_txn.id, debits_total, credits_total, v_user_data
    from data.accounts where id = v_txn.debit_account_id;

    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select v_txn.credit_account_id, v_txn.id, debits_total, credits_total, v_user_data
    from data.accounts where id = v_txn.credit_account_id;

    return p_transaction_uuid;
end;
$$ language plpgsql security definer;

-- releases (voids) a pending transfer. deletes hold rows, no counter changes.
create function ledger.release(
    p_transaction_uuid text
) returns void as $$
declare
    v_txn data.transactions;
begin
    select * into v_txn
    from data.transactions
    where uuid = p_transaction_uuid and user_data = utils.get_user();

    if v_txn.id is null then
        raise exception 'Transaction not found: %', p_transaction_uuid;
    end if;

    if v_txn.status != 'pending' then
        raise exception 'Transaction % is not pending (status: %)', p_transaction_uuid, v_txn.status;
    end if;

    -- 1. UPDATE transaction status
    update data.transactions set status = 'voided', timeout_at = null
    where id = v_txn.id;

    -- 2. DELETE pending hold rows
    delete from data.pending where transaction_id = v_txn.id;
end;
$$ language plpgsql security definer;

-- expires all pending transfers past their timeout. returns count of expired.
create function ledger.expire_pending() returns integer as $$
declare
    v_expired_txn record;
    v_count integer := 0;
begin
    for v_expired_txn in
        select distinct transaction_id
        from data.pending
        where timeout_at is not null and timeout_at < now()
    loop
        -- update transaction status to expired
        update data.transactions set status = 'expired', timeout_at = null
        where id = v_expired_txn.transaction_id and status = 'pending';

        -- delete pending rows
        delete from data.pending where transaction_id = v_expired_txn.transaction_id;

        v_count := v_count + 1;
    end loop;

    return v_count;
end;
$$ language plpgsql security definer;

-- update the checked path to include pending amounts in constraint checks
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
    v_pending_sum bigint;
begin
    -- update debit account with constraint check (including pending holds)
    select coalesce(sum(amount), 0) into v_pending_sum
    from data.pending where account_id = p_debit_id;

    update data.accounts
    set debits_total = debits_total + p_amount
    where id = p_debit_id
      and (not debits_must_not_exceed_credits
           or debits_total + v_pending_sum + p_amount <= credits_total);

    if not found then
        raise exception 'Transaction rejected: would exceed credit balance on account %', p_debit_uuid;
    end if;

    -- update credit account with constraint check (including pending holds)
    select coalesce(sum(amount), 0) into v_pending_sum
    from data.pending where account_id = p_credit_id;

    update data.accounts
    set credits_total = credits_total + p_amount
    where id = p_credit_id
      and (not credits_must_not_exceed_debits
           or credits_total + v_pending_sum + p_amount <= debits_total);

    if not found then
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

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists ledger.expire_pending();
drop function if exists ledger.release(text);
drop function if exists ledger.commit(text, bigint);
drop function if exists ledger.reserve(text, text, text, bigint, integer, date, text, text);
drop policy if exists pending_policy on data.pending;
drop table if exists data.pending;
alter table data.transactions drop column if exists timeout_at;

-- +goose StatementEnd
