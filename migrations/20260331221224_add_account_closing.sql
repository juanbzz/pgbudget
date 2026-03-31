-- +goose Up
-- +goose StatementBegin

-- add closed flag to accounts
alter table data.accounts add column is_closed boolean not null default false;

-- closes an account permanently. no new transactions except releasing/voiding pending holds.
create function ledger.close_account(
    p_account_uuid text
) returns void as $$
declare
    v_account_id bigint;
begin
    select id into v_account_id
    from data.accounts
    where uuid = p_account_uuid and user_data = utils.get_user();

    if v_account_id is null then
        raise exception 'Account not found: %', p_account_uuid;
    end if;

    update data.accounts set is_closed = true where id = v_account_id;
end;
$$ language plpgsql security definer;

-- update post_transaction to reject closed accounts
create or replace function ledger.post_transaction(
    p_ledger_uuid text,
    p_debit_account_uuid text,
    p_credit_account_uuid text,
    p_amount bigint,
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

    -- closed account check
    if v_debit.is_closed then
        raise exception 'Account % is closed', p_debit_account_uuid;
    end if;

    select * into v_credit
    from data.accounts
    where uuid = p_credit_account_uuid and ledger_id = v_ledger_id and user_data = v_user_data;

    if v_credit.id is null then
        raise exception 'Credit account not found: %', p_credit_account_uuid;
    end if;

    -- closed account check
    if v_credit.is_closed then
        raise exception 'Account % is closed', p_credit_account_uuid;
    end if;

    if v_debit.id = v_credit.id then
        raise exception 'Debit and credit accounts must be different';
    end if;

    begin
        insert into data.transactions (
            ledger_id, debit_account_id, credit_account_id,
            amount, date, description, user_data, idempotency_key
        ) values (
            v_ledger_id, v_debit.id, v_credit.id,
            p_amount, p_date, p_description, v_user_data, p_idempotency_key
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

-- update reserve to reject closed accounts
create or replace function ledger.reserve(
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
    if p_idempotency_key is not null then
        select uuid into v_existing_uuid
        from data.transactions
        where idempotency_key = p_idempotency_key and user_data = v_user_data;

        if v_existing_uuid is not null then
            return v_existing_uuid;
        end if;
    end if;

    if p_amount <= 0 then
        raise exception 'Reserve amount must be positive: %', p_amount;
    end if;

    if p_timeout_seconds is not null and p_timeout_seconds > 0 then
        v_timeout_at := now() + (p_timeout_seconds || ' seconds')::interval;
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

    -- closed account check
    if v_debit.is_closed then
        raise exception 'Account % is closed', p_debit_account_uuid;
    end if;

    select * into v_credit
    from data.accounts
    where uuid = p_credit_account_uuid and ledger_id = v_ledger_id and user_data = v_user_data;

    if v_credit.id is null then
        raise exception 'Credit account not found: %', p_credit_account_uuid;
    end if;

    -- closed account check
    if v_credit.is_closed then
        raise exception 'Account % is closed', p_credit_account_uuid;
    end if;

    if v_debit.id = v_credit.id then
        raise exception 'Debit and credit accounts must be different';
    end if;

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

    insert into data.pending (account_id, transaction_id, amount, timeout_at, user_data)
    values (v_debit.id, v_txn_id, p_amount, v_timeout_at, v_user_data);

    insert into data.pending (account_id, transaction_id, amount, timeout_at, user_data)
    values (v_credit.id, v_txn_id, p_amount, v_timeout_at, v_user_data);

    return v_txn_uuid;
end;
$$ language plpgsql security definer;

-- update commit to reject closed accounts
create or replace function ledger.commit(
    p_transaction_uuid text,
    p_amount bigint default null
) returns text as $$
declare
    v_txn data.transactions;
    v_commit_amount bigint;
    v_user_data text := utils.get_user();
    v_debit_closed boolean;
    v_credit_closed boolean;
begin
    select * into v_txn
    from data.transactions
    where uuid = p_transaction_uuid and user_data = v_user_data;

    if v_txn.id is null then
        raise exception 'Transaction not found: %', p_transaction_uuid;
    end if;

    if v_txn.status != 'pending' then
        raise exception 'Transaction % is not pending (status: %)', p_transaction_uuid, v_txn.status;
    end if;

    if v_txn.timeout_at is not null and v_txn.timeout_at < now() then
        raise exception 'Transaction % has expired', p_transaction_uuid;
    end if;

    -- closed account check
    select is_closed into v_debit_closed from data.accounts where id = v_txn.debit_account_id;
    select is_closed into v_credit_closed from data.accounts where id = v_txn.credit_account_id;

    if v_debit_closed then
        raise exception 'Debit account is closed';
    end if;
    if v_credit_closed then
        raise exception 'Credit account is closed';
    end if;

    v_commit_amount := coalesce(p_amount, v_txn.amount);

    if v_commit_amount <= 0 then
        raise exception 'Commit amount must be positive: %', v_commit_amount;
    end if;

    if v_commit_amount > v_txn.amount then
        raise exception 'Commit amount % exceeds reserved amount %', v_commit_amount, v_txn.amount;
    end if;

    update data.transactions
    set status = 'posted', amount = v_commit_amount, timeout_at = null
    where id = v_txn.id;

    delete from data.pending where transaction_id = v_txn.id;

    update data.accounts set debits_total = debits_total + v_commit_amount
    where id = v_txn.debit_account_id;

    update data.accounts set credits_total = credits_total + v_commit_amount
    where id = v_txn.credit_account_id;

    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select v_txn.debit_account_id, v_txn.id, debits_total, credits_total, v_user_data
    from data.accounts where id = v_txn.debit_account_id;

    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select v_txn.credit_account_id, v_txn.id, debits_total, credits_total, v_user_data
    from data.accounts where id = v_txn.credit_account_id;

    return p_transaction_uuid;
end;
$$ language plpgsql security definer;

-- update correct to reject closed accounts
create or replace function ledger.correct(
    p_transaction_uuid text,
    p_debit_account_uuid text default null,
    p_credit_account_uuid text default null,
    p_amount bigint default null,
    p_description text default null,
    p_date date default null,
    p_reason text default 'Corrected'
) returns text as $$
declare
    v_original data.transactions;
    v_ledger_uuid text;
    v_orig_debit_uuid text;
    v_orig_credit_uuid text;
    v_new_debit_uuid text;
    v_new_credit_uuid text;
    v_reversal_uuid text;
    v_correction_uuid text;
    v_reversal_id bigint;
    v_correction_id bigint;
    v_new_debit_closed boolean;
    v_new_credit_closed boolean;
begin
    select t.* into v_original
    from data.transactions t
    where t.uuid = p_transaction_uuid and t.user_data = utils.get_user();

    if v_original.id is null then
        raise exception 'Transaction not found: %', p_transaction_uuid;
    end if;

    select uuid into v_ledger_uuid from data.ledgers where id = v_original.ledger_id;
    select uuid into v_orig_debit_uuid from data.accounts where id = v_original.debit_account_id;
    select uuid into v_orig_credit_uuid from data.accounts where id = v_original.credit_account_id;

    v_new_debit_uuid := coalesce(p_debit_account_uuid, v_orig_debit_uuid);
    v_new_credit_uuid := coalesce(p_credit_account_uuid, v_orig_credit_uuid);

    -- closed account check on the corrected transaction's accounts
    select is_closed into v_new_debit_closed from data.accounts where uuid = v_new_debit_uuid;
    select is_closed into v_new_credit_closed from data.accounts where uuid = v_new_credit_uuid;

    if v_new_debit_closed then
        raise exception 'Account % is closed', v_new_debit_uuid;
    end if;
    if v_new_credit_closed then
        raise exception 'Account % is closed', v_new_credit_uuid;
    end if;

    -- reversal is allowed on closed accounts (void uses post_transaction internally,
    -- but we call it directly here to bypass the closed check for the reversal)
    -- 1. create reversal — insert directly, bypassing closed check
    insert into data.transactions (
        ledger_id, debit_account_id, credit_account_id,
        amount, date, description, user_data
    ) values (
        v_original.ledger_id, v_original.credit_account_id, v_original.debit_account_id,
        v_original.amount, v_original.date,
        'REVERSAL: ' || coalesce(v_original.description, ''), utils.get_user()
    ) returning id, uuid into v_reversal_id, v_reversal_uuid;

    -- update counters for reversal
    update data.accounts set debits_total = debits_total + v_original.amount
    where id = v_original.credit_account_id;
    update data.accounts set credits_total = credits_total + v_original.amount
    where id = v_original.debit_account_id;

    -- balance history for reversal
    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select v_original.credit_account_id, v_reversal_id, debits_total, credits_total, utils.get_user()
    from data.accounts where id = v_original.credit_account_id;
    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select v_original.debit_account_id, v_reversal_id, debits_total, credits_total, utils.get_user()
    from data.accounts where id = v_original.debit_account_id;

    -- 2. create the corrected transaction via post_transaction (respects closed check)
    select ledger.post_transaction(
        v_ledger_uuid,
        v_new_debit_uuid,
        v_new_credit_uuid,
        coalesce(p_amount, v_original.amount),
        coalesce(p_date, v_original.date),
        coalesce(p_description, v_original.description)
    ) into v_correction_uuid;

    select id into v_correction_id from data.transactions where uuid = v_correction_uuid;

    -- log
    insert into data.transaction_log (
        original_transaction_id, reversal_transaction_id, correction_transaction_id,
        mutation_type, reason, user_data
    ) values (
        v_original.id, v_reversal_id, v_correction_id,
        'correction', p_reason, utils.get_user()
    );

    return v_correction_uuid;
end;
$$ language plpgsql security definer;

-- update void to bypass closed check — reversals must always be possible.
-- inserts directly instead of calling ledger.post_transaction().
create or replace function ledger.void(
    p_transaction_uuid text,
    p_reason text default 'Voided'
) returns text as $$
declare
    v_original data.transactions;
    v_reversal_id bigint;
    v_reversal_uuid text;
    v_user_data text := utils.get_user();
begin
    select t.* into v_original
    from data.transactions t
    where t.uuid = p_transaction_uuid and t.user_data = v_user_data;

    if v_original.id is null then
        raise exception 'Transaction not found: %', p_transaction_uuid;
    end if;

    -- insert reversal directly (bypass closed check)
    insert into data.transactions (
        ledger_id, debit_account_id, credit_account_id,
        amount, date, description, user_data
    ) values (
        v_original.ledger_id,
        v_original.credit_account_id,  -- swap
        v_original.debit_account_id,   -- swap
        v_original.amount,
        v_original.date,
        'VOIDED: ' || coalesce(v_original.description, ''),
        v_user_data
    ) returning id, uuid into v_reversal_id, v_reversal_uuid;

    -- update counters
    update data.accounts set debits_total = debits_total + v_original.amount
    where id = v_original.credit_account_id;
    update data.accounts set credits_total = credits_total + v_original.amount
    where id = v_original.debit_account_id;

    -- balance history
    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select v_original.credit_account_id, v_reversal_id, debits_total, credits_total, v_user_data
    from data.accounts where id = v_original.credit_account_id;

    insert into data.balances (account_id, transaction_id, debits_total, credits_total, user_data)
    select v_original.debit_account_id, v_reversal_id, debits_total, credits_total, v_user_data
    from data.accounts where id = v_original.debit_account_id;

    -- log
    insert into data.transaction_log (
        original_transaction_id, reversal_transaction_id,
        mutation_type, reason, user_data
    ) values (
        v_original.id, v_reversal_id,
        'deletion', p_reason, v_user_data
    );

    return v_reversal_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists ledger.close_account(text);
alter table data.accounts drop column if exists is_closed;

-- +goose StatementEnd
