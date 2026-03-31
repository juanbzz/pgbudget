-- +goose Up
-- +goose StatementBegin

-- add idempotency key column to transactions.
-- partial unique index: only non-null keys are indexed, zero overhead for default usage.
alter table data.transactions add column idempotency_key text;

create unique index idx_transactions_idempotency
    on data.transactions(idempotency_key, user_data)
    where idempotency_key is not null;

-- drop the old signature to avoid overload ambiguity
drop function if exists ledger.post_transaction(text, text, text, bigint, date, text);

-- recreate with optional idempotency key
create function ledger.post_transaction(
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
    -- idempotency check: if key provided, check for existing transaction
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
        raise exception 'Transaction amount must be positive: %', p_amount;
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

    -- reject same account
    if v_debit.id = v_credit.id then
        raise exception 'Debit and credit accounts must be different';
    end if;

    -- 1. INSERT transaction (with idempotency key if provided)
    begin
        insert into data.transactions (
            ledger_id, debit_account_id, credit_account_id,
            amount, date, description, user_data, idempotency_key
        ) values (
            v_ledger_id, v_debit.id, v_credit.id,
            p_amount, p_date, p_description, v_user_data, p_idempotency_key
        ) returning id, uuid into v_txn_id, v_txn_uuid;
    exception when unique_violation then
        -- concurrent race: another call with the same key won
        if p_idempotency_key is not null then
            select uuid into v_existing_uuid
            from data.transactions
            where idempotency_key = p_idempotency_key and user_data = v_user_data;

            if v_existing_uuid is not null then
                return v_existing_uuid;
            end if;
        end if;
        -- if not an idempotency conflict, re-raise
        raise;
    end;

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

drop index if exists data.idx_transactions_idempotency;
alter table data.transactions drop column if exists idempotency_key;

-- +goose StatementEnd
