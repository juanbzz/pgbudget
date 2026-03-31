-- +goose Up
-- +goose StatementBegin

-- voids a transaction by creating a reversal (swapped debit/credit, same amount).
-- uses ledger.post_transaction() so counters and balances update correctly.
create function ledger.void(
    p_transaction_uuid text,
    p_reason text default 'Voided'
) returns text as $$
declare
    v_original data.transactions;
    v_ledger_uuid text;
    v_debit_uuid text;
    v_credit_uuid text;
    v_reversal_uuid text;
    v_reversal_id bigint;
begin
    -- get the original transaction
    select t.* into v_original
    from data.transactions t
    where t.uuid = p_transaction_uuid and t.user_data = utils.get_user();

    if v_original.id is null then
        raise exception 'Transaction not found: %', p_transaction_uuid;
    end if;

    -- look up uuids for the ledger and accounts
    select uuid into v_ledger_uuid from data.ledgers where id = v_original.ledger_id;
    select uuid into v_debit_uuid from data.accounts where id = v_original.debit_account_id;
    select uuid into v_credit_uuid from data.accounts where id = v_original.credit_account_id;

    -- create reversal: swap debit/credit of the original
    select ledger.post_transaction(
        v_ledger_uuid,
        v_credit_uuid,    -- original credit becomes debit (reversal)
        v_debit_uuid,     -- original debit becomes credit (reversal)
        v_original.amount,
        v_original.date,
        'VOIDED: ' || coalesce(v_original.description, '')
    ) into v_reversal_uuid;

    -- get the reversal's internal id for the log
    select id into v_reversal_id from data.transactions where uuid = v_reversal_uuid;

    -- record in transaction log
    insert into data.transaction_log (
        original_transaction_id, reversal_transaction_id,
        mutation_type, reason, user_data
    ) values (
        v_original.id, v_reversal_id,
        'deletion', p_reason, utils.get_user()
    );

    return v_reversal_uuid;
end;
$$ language plpgsql security definer;

-- corrects a transaction by creating a reversal of the original + a new corrected transaction.
-- only changed fields need to be provided — unchanged fields carry over from the original.
-- uses ledger.post_transaction() for both the reversal and the correction.
create function ledger.correct(
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
begin
    -- get the original transaction
    select t.* into v_original
    from data.transactions t
    where t.uuid = p_transaction_uuid and t.user_data = utils.get_user();

    if v_original.id is null then
        raise exception 'Transaction not found: %', p_transaction_uuid;
    end if;

    -- look up uuids
    select uuid into v_ledger_uuid from data.ledgers where id = v_original.ledger_id;
    select uuid into v_orig_debit_uuid from data.accounts where id = v_original.debit_account_id;
    select uuid into v_orig_credit_uuid from data.accounts where id = v_original.credit_account_id;

    -- use provided values or fall back to original
    v_new_debit_uuid := coalesce(p_debit_account_uuid, v_orig_debit_uuid);
    v_new_credit_uuid := coalesce(p_credit_account_uuid, v_orig_credit_uuid);

    -- 1. create reversal of the original
    select ledger.post_transaction(
        v_ledger_uuid,
        v_orig_credit_uuid,   -- swap
        v_orig_debit_uuid,    -- swap
        v_original.amount,
        v_original.date,
        'REVERSAL: ' || coalesce(v_original.description, '')
    ) into v_reversal_uuid;

    -- 2. create the corrected transaction
    select ledger.post_transaction(
        v_ledger_uuid,
        v_new_debit_uuid,
        v_new_credit_uuid,
        coalesce(p_amount, v_original.amount),
        coalesce(p_date, v_original.date),
        coalesce(p_description, v_original.description)
    ) into v_correction_uuid;

    -- get internal ids for the log
    select id into v_reversal_id from data.transactions where uuid = v_reversal_uuid;
    select id into v_correction_id from data.transactions where uuid = v_correction_uuid;

    -- record in transaction log
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

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists ledger.correct(text, text, text, bigint, text, date, text);
drop function if exists ledger.void(text, text);

-- +goose StatementEnd
