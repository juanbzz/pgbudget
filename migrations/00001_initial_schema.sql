-- +goose Up
-- +goose StatementBegin

-- pgbudget v0.5.0 — Complete Schema
-- Generic double-entry ledger engine (TigerBeetle-inspired).
-- For fresh installations. Pre-1.0: the budget layer is not yet built.
--
-- Schemas: data (tables), utils (helpers), ledger (public API).
-- Multi-tenancy via user_data column + RLS on all data tables.
-- 18 ledger.* functions; raw debit/credit counters (no signed balances, no account types).
-- v1.0.0 will add the budget.* schema on top of this engine.

--
-- Name: data; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA data;

--
-- Name: ledger; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ledger;

--
-- Name: utils; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA utils;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: public; Owner: -
--
-- Required by utils.nanoid / utils.nanoid_optimized for gen_random_bytes().

CREATE EXTENSION IF NOT EXISTS pgcrypto;

--
-- Name: get_user(); Type: FUNCTION; Schema: utils; Owner: -
--

CREATE FUNCTION utils.get_user() RETURNS text
    LANGUAGE plpgsql STABLE
    AS $$
begin
    -- Try to get application user from session variable first
    -- This allows the Go microservice to set user context per request
    -- Falls back to current_user for tests and direct database access
    return coalesce(
        current_setting('app.current_user_id', true),
        current_user
    );
end;
$$;

--
-- Name: nanoid(integer, text, double precision); Type: FUNCTION; Schema: utils; Owner: -
--

CREATE FUNCTION utils.nanoid(size integer DEFAULT 21, alphabet text DEFAULT '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'::text, additionalbytesfactor double precision DEFAULT 1.6) RETURNS text
    LANGUAGE plpgsql PARALLEL SAFE
    AS $$
DECLARE
    alphabetArray  text[];
    alphabetLength int := 64;
    mask           int := 63;
    step           int := 34;
BEGIN
    IF size IS NULL OR size < 1 THEN
        RAISE EXCEPTION 'The size must be defined and greater than 0!';
    END IF;

    IF alphabet IS NULL OR length(alphabet) = 0 OR length(alphabet) > 255 THEN
        RAISE EXCEPTION 'The alphabet can''t be undefined, zero or bigger than 255 symbols!';
    END IF;

    IF additionalBytesFactor IS NULL OR additionalBytesFactor < 1 THEN
        RAISE EXCEPTION 'The additional bytes factor can''t be less than 1!';
    END IF;

    alphabetArray := regexp_split_to_array(alphabet, '');
    alphabetLength := array_length(alphabetArray, 1);
    mask := (2 << cast(floor(log(alphabetLength - 1) / log(2)) as int)) - 1;
    step := cast(ceil(additionalBytesFactor * mask * size / alphabetLength) AS int);

    IF step > 1024 THEN
        step := 1024; -- The step size % can''t be bigger then 1024!
    END IF;

    RETURN utils.nanoid_optimized(size, alphabet, mask, step);
END
$$;

--
-- Name: nanoid_optimized(integer, text, integer, integer); Type: FUNCTION; Schema: utils; Owner: -
--

CREATE FUNCTION utils.nanoid_optimized(size integer, alphabet text, mask integer, step integer) RETURNS text
    LANGUAGE plpgsql PARALLEL SAFE
    AS $$
DECLARE
    idBuilder      text := '';
    counter        int  := 0;
    bytes          bytea;
    alphabetIndex  int;
    alphabetArray  text[];
    alphabetLength int  := 64;
BEGIN
    alphabetArray := regexp_split_to_array(alphabet, '');
    alphabetLength := array_length(alphabetArray, 1);

    LOOP
        bytes := gen_random_bytes(step);
        FOR counter IN 0..step - 1
            LOOP
                alphabetIndex := (get_byte(bytes, counter) & mask) + 1;
                IF alphabetIndex <= alphabetLength THEN
                    idBuilder := idBuilder || alphabetArray[alphabetIndex];
                    IF length(idBuilder) = size THEN
                        RETURN idBuilder;
                    END IF;
                END IF;
            END LOOP;
    END LOOP;
END
$$;

--
-- Name: set_updated_at_fn(); Type: FUNCTION; Schema: utils; Owner: -
--

CREATE FUNCTION utils.set_updated_at_fn() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
    new.updated_at := current_timestamp;
    return new;
end;
$$;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: accounts; Type: TABLE; Schema: data; Owner: -
--

CREATE TABLE data.accounts (
    id bigint NOT NULL,
    uuid text DEFAULT utils.nanoid(8) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    name text NOT NULL,
    description text,
    metadata jsonb,
    user_data text DEFAULT utils.get_user() NOT NULL,
    ledger_id bigint NOT NULL,
    debits_total bigint DEFAULT 0 NOT NULL,
    credits_total bigint DEFAULT 0 NOT NULL,
    debits_must_not_exceed_credits boolean DEFAULT false NOT NULL,
    credits_must_not_exceed_debits boolean DEFAULT false NOT NULL,
    is_closed boolean DEFAULT false NOT NULL,
    visibility text DEFAULT 'standard'::text NOT NULL,
    CONSTRAINT accounts_description_length_check CHECK ((char_length(description) <= 255)),
    CONSTRAINT accounts_name_length_check CHECK ((char_length(name) <= 255)),
    CONSTRAINT accounts_user_data_length_check CHECK ((char_length(user_data) <= 255)),
    CONSTRAINT accounts_visibility_check CHECK ((visibility = ANY (ARRAY['standard'::text, 'internal'::text])))
);

--
-- Name: accounts_id_seq; Type: SEQUENCE; Schema: data; Owner: -
--

ALTER TABLE data.accounts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME data.accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: balances; Type: TABLE; Schema: data; Owner: -
--

CREATE TABLE data.balances (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    transaction_id bigint NOT NULL,
    debits_total bigint NOT NULL,
    credits_total bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    user_data text DEFAULT utils.get_user() NOT NULL
);

--
-- Name: balances_id_seq; Type: SEQUENCE; Schema: data; Owner: -
--

ALTER TABLE data.balances ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME data.balances_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: ledgers; Type: TABLE; Schema: data; Owner: -
--

CREATE TABLE data.ledgers (
    id bigint NOT NULL,
    uuid text DEFAULT utils.nanoid(8) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    name text NOT NULL,
    description text,
    metadata jsonb,
    user_data text DEFAULT utils.get_user() NOT NULL,
    CONSTRAINT ledgers_description_length_check CHECK ((char_length(description) <= 255)),
    CONSTRAINT ledgers_name_length_check CHECK ((char_length(name) <= 255)),
    CONSTRAINT ledgers_user_data_length_check CHECK ((char_length(user_data) <= 255))
);

--
-- Name: ledgers_id_seq; Type: SEQUENCE; Schema: data; Owner: -
--

ALTER TABLE data.ledgers ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME data.ledgers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: pending; Type: TABLE; Schema: data; Owner: -
--

CREATE TABLE data.pending (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    transaction_id bigint NOT NULL,
    amount bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    timeout_at timestamp with time zone,
    user_data text DEFAULT utils.get_user() NOT NULL
);

--
-- Name: pending_id_seq; Type: SEQUENCE; Schema: data; Owner: -
--

ALTER TABLE data.pending ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME data.pending_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: transaction_log; Type: TABLE; Schema: data; Owner: -
--

CREATE TABLE data.transaction_log (
    id bigint NOT NULL,
    original_transaction_id bigint NOT NULL,
    reversal_transaction_id bigint,
    correction_transaction_id bigint,
    mutation_type text NOT NULL,
    reason text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    user_data text DEFAULT utils.get_user() NOT NULL,
    CONSTRAINT transaction_log_mutation_type_check CHECK ((mutation_type = ANY (ARRAY['correction'::text, 'deletion'::text])))
);

--
-- Name: transaction_log_id_seq; Type: SEQUENCE; Schema: data; Owner: -
--

ALTER TABLE data.transaction_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME data.transaction_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: transactions; Type: TABLE; Schema: data; Owner: -
--

CREATE TABLE data.transactions (
    id bigint NOT NULL,
    uuid text DEFAULT utils.nanoid(8) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    amount bigint DEFAULT 0 NOT NULL,
    date date,
    description text,
    metadata jsonb,
    status text DEFAULT 'posted'::text NOT NULL,
    credit_account_id bigint NOT NULL,
    debit_account_id bigint NOT NULL,
    deleted_at timestamp with time zone,
    user_data text DEFAULT utils.get_user() NOT NULL,
    ledger_id bigint NOT NULL,
    idempotency_key text,
    timeout_at timestamp with time zone,
    link_id bigint,
    CONSTRAINT transactions_amount_positive CHECK ((amount >= 0)),
    CONSTRAINT transactions_description_length_check CHECK ((char_length(description) < 255)),
    CONSTRAINT transactions_different_accounts CHECK ((credit_account_id <> debit_account_id)),
    CONSTRAINT transactions_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'posted'::text, 'voided'::text, 'expired'::text]))),
    CONSTRAINT transactions_user_data_length_check CHECK ((char_length(user_data) < 255))
);

--
-- Name: transactions_id_seq; Type: SEQUENCE; Schema: data; Owner: -
--

ALTER TABLE data.transactions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME data.transactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: metadata; Type: TABLE; Schema: utils; Owner: -
--

CREATE TABLE utils.metadata (
    key text NOT NULL,
    value text NOT NULL
);

--
-- Name: accounts accounts_name_ledger_unique; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.accounts
    ADD CONSTRAINT accounts_name_ledger_unique UNIQUE (name, ledger_id, user_data);

--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);

--
-- Name: accounts accounts_uuid_unique; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.accounts
    ADD CONSTRAINT accounts_uuid_unique UNIQUE (uuid);

--
-- Name: balances balances_account_transaction_unique; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.balances
    ADD CONSTRAINT balances_account_transaction_unique UNIQUE (account_id, transaction_id, user_data);

--
-- Name: balances balances_pkey; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.balances
    ADD CONSTRAINT balances_pkey PRIMARY KEY (id);

--
-- Name: ledgers ledgers_name_user_unique; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.ledgers
    ADD CONSTRAINT ledgers_name_user_unique UNIQUE (name, user_data);

--
-- Name: ledgers ledgers_pkey; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.ledgers
    ADD CONSTRAINT ledgers_pkey PRIMARY KEY (id);

--
-- Name: ledgers ledgers_uuid_unique; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.ledgers
    ADD CONSTRAINT ledgers_uuid_unique UNIQUE (uuid);

--
-- Name: pending pending_account_transaction_unique; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.pending
    ADD CONSTRAINT pending_account_transaction_unique UNIQUE (account_id, transaction_id, user_data);

--
-- Name: pending pending_pkey; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.pending
    ADD CONSTRAINT pending_pkey PRIMARY KEY (id);

--
-- Name: transaction_log transaction_log_id_pk; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.transaction_log
    ADD CONSTRAINT transaction_log_id_pk PRIMARY KEY (id);

--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);

--
-- Name: transactions transactions_uuid_unique; Type: CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.transactions
    ADD CONSTRAINT transactions_uuid_unique UNIQUE (uuid);

--
-- Name: metadata metadata_pkey; Type: CONSTRAINT; Schema: utils; Owner: -
--

ALTER TABLE ONLY utils.metadata
    ADD CONSTRAINT metadata_pkey PRIMARY KEY (key);

--
-- Name: idx_balances_account_transaction; Type: INDEX; Schema: data; Owner: -
--

CREATE INDEX idx_balances_account_transaction ON data.balances USING btree (account_id, transaction_id DESC);

--
-- Name: idx_balances_user_data; Type: INDEX; Schema: data; Owner: -
--

CREATE INDEX idx_balances_user_data ON data.balances USING btree (user_data);

--
-- Name: idx_pending_account; Type: INDEX; Schema: data; Owner: -
--

CREATE INDEX idx_pending_account ON data.pending USING btree (account_id);

--
-- Name: idx_pending_timeout; Type: INDEX; Schema: data; Owner: -
--

CREATE INDEX idx_pending_timeout ON data.pending USING btree (timeout_at) WHERE (timeout_at IS NOT NULL);

--
-- Name: idx_pending_user_data; Type: INDEX; Schema: data; Owner: -
--

CREATE INDEX idx_pending_user_data ON data.pending USING btree (user_data);

--
-- Name: idx_transaction_log_original_id; Type: INDEX; Schema: data; Owner: -
--

CREATE INDEX idx_transaction_log_original_id ON data.transaction_log USING btree (original_transaction_id);

--
-- Name: idx_transactions_idempotency; Type: INDEX; Schema: data; Owner: -
--

CREATE UNIQUE INDEX idx_transactions_idempotency ON data.transactions USING btree (idempotency_key, user_data) WHERE (idempotency_key IS NOT NULL);

--
-- Name: idx_transactions_link; Type: INDEX; Schema: data; Owner: -
--

CREATE INDEX idx_transactions_link ON data.transactions USING btree (link_id) WHERE (link_id IS NOT NULL);

--
-- Name: close_account(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.close_account(p_account_uuid text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: commit(text, bigint); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.commit(p_transaction_uuid text, p_amount bigint DEFAULT NULL::bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: correct(text, text, text, bigint, text, date, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.correct(p_transaction_uuid text, p_debit_account_uuid text DEFAULT NULL::text, p_credit_account_uuid text DEFAULT NULL::text, p_amount bigint DEFAULT NULL::bigint, p_description text DEFAULT NULL::text, p_date date DEFAULT NULL::date, p_reason text DEFAULT 'Corrected'::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: create_account(text, text, text, boolean, boolean); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.create_account(p_ledger_uuid text, p_name text, p_description text DEFAULT NULL::text, p_debits_must_not_exceed_credits boolean DEFAULT false, p_credits_must_not_exceed_debits boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
        debits_must_not_exceed_credits, credits_must_not_exceed_debits
    ) values (
        v_name, p_description, v_ledger_id, utils.get_user(),
        p_debits_must_not_exceed_credits, p_credits_must_not_exceed_debits
    ) returning uuid into v_account_uuid;

    return v_account_uuid;
end;
$$;

--
-- Name: create_ledger(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.create_ledger(p_name text, p_description text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: delete_ledger(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.delete_ledger(p_ledger_uuid text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
    v_ledger_id bigint;
begin
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    -- clean up pending holds
    delete from data.pending
    where account_id in (select id from data.accounts where ledger_id = v_ledger_id);

    -- clean up balance history
    delete from data.balances
    where account_id in (select id from data.accounts where ledger_id = v_ledger_id);

    -- CASCADE handles accounts, transactions, transaction_log, groups
    delete from data.ledgers where id = v_ledger_id;
end;
$$;

--
-- Name: expire_pending(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.expire_pending() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: get_accounts(text, boolean); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.get_accounts(p_ledger_uuid text, p_include_internal boolean DEFAULT false) RETURNS TABLE(account_uuid text, account_name text, description text, visibility text, debits_must_not_exceed_credits boolean, credits_must_not_exceed_debits boolean, is_closed boolean, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: get_balance(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.get_balance(p_account_uuid text) RETURNS TABLE(debits_total bigint, credits_total bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    AS $$
declare
    v_account_id bigint;
begin
    select a.id into v_account_id
    from data.accounts a
    where a.uuid = p_account_uuid and a.user_data = utils.get_user();

    if v_account_id is null then
        raise exception 'Account not found: %', p_account_uuid;
    end if;

    return query
    select a.debits_total, a.credits_total
    from data.accounts a
    where a.id = v_account_id;
end;
$$;

--
-- Name: get_balances(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.get_balances(p_ledger_uuid text) RETURNS TABLE(account_uuid text, account_name text, debits_total bigint, credits_total bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    AS $$
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
        a.debits_total,
        a.credits_total
    from data.accounts a
    where a.ledger_id = v_ledger_id
      and a.user_data = utils.get_user()
    order by a.name;
end;
$$;

--
-- Name: get_history(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.get_history(p_account_uuid text) RETURNS TABLE(transaction_uuid text, date date, description text, counterparty text, amount bigint, direction text, debits_total bigint, credits_total bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    AS $$
declare
    v_account_id bigint;
    v_ledger_id bigint;
begin
    select a.id, a.ledger_id
    into v_account_id, v_ledger_id
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
        -- resolve counterparty: if the other account is internal,
        -- follow the link_id to find the real counterparty
        case
            when cp.visibility != 'standard' and t.link_id is not null then
                coalesce(
                    (select a2.name from data.transactions t2
                     join data.accounts a2 on (
                         case when t2.debit_account_id = cp.id then t2.credit_account_id
                              else t2.debit_account_id end = a2.id
                     )
                     where t2.link_id = t.link_id
                       and t2.id != t.id
                     limit 1),
                    cp.name
                )
            else cp.name
        end as counterparty,
        t.amount,
        case
            when t.debit_account_id = v_account_id then 'debit'
            else 'credit'
        end as direction,
        coalesce(b.debits_total, 0) as debits_total,
        coalesce(b.credits_total, 0) as credits_total
    from
        data.transactions t
        left join data.balances b on (
            b.transaction_id = t.id
            and b.account_id = v_account_id
            and b.user_data = utils.get_user()
        )
        -- get the counterparty account
        join data.accounts cp on (
            cp.id = case
                when t.debit_account_id = v_account_id then t.credit_account_id
                else t.debit_account_id
            end
        )
    where
        (t.debit_account_id = v_account_id or t.credit_account_id = v_account_id)
        and t.deleted_at is null
    order by
        t.date desc,
        t.created_at desc;
end;
$$;

--
-- Name: post_linked(text, jsonb); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.post_linked(p_ledger_uuid text, p_transactions jsonb) RETURNS text[]
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
    v_ledger_id bigint;
    v_user_data text := utils.get_user();
    v_entry jsonb;
    v_uuid text;
    v_uuids text[] := '{}';
    v_first_id bigint;
    v_debit text;
    v_credit text;
    v_amount bigint;
    v_date date;
    v_description text;
    v_is_first boolean := true;
begin
    -- validate ledger
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = v_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    if jsonb_typeof(p_transactions) != 'array' then
        raise exception 'Transactions must be a JSON array';
    end if;

    if jsonb_array_length(p_transactions) < 2 then
        raise exception 'Linked transfers require at least 2 transactions';
    end if;

    -- post each transaction
    for v_entry in select * from jsonb_array_elements(p_transactions)
    loop
        v_debit := v_entry->>'debit';
        v_credit := v_entry->>'credit';
        v_amount := (v_entry->>'amount')::bigint;

        if v_debit is null then
            raise exception 'Missing "debit" field in transaction entry';
        end if;
        if v_credit is null then
            raise exception 'Missing "credit" field in transaction entry';
        end if;
        if v_amount is null then
            raise exception 'Missing "amount" field in transaction entry';
        end if;

        v_date := coalesce((v_entry->>'date')::date, current_date);
        v_description := v_entry->>'description';

        -- post via ledger.post_transaction
        select ledger.post_transaction(
            p_ledger_uuid, v_debit, v_credit, v_amount, v_date, v_description
        ) into v_uuid;

        -- capture the first transaction's internal id as the link_id
        if v_is_first then
            select id into v_first_id from data.transactions where uuid = v_uuid;
            v_is_first := false;
        end if;

        v_uuids := array_append(v_uuids, v_uuid);
    end loop;

    -- set link_id on all transactions in the group
    update data.transactions
    set link_id = v_first_id
    where uuid = any(v_uuids);

    return v_uuids;
end;
$$;

--
-- Name: post_transaction(text, text, text, bigint, date, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.post_transaction(p_ledger_uuid text, p_debit_account_uuid text, p_credit_account_uuid text, p_amount bigint, p_date date DEFAULT CURRENT_DATE, p_description text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: post_transactions(text, jsonb); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.post_transactions(p_ledger_uuid text, p_transactions jsonb) RETURNS text[]
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
    v_ledger_id bigint;
    v_entry jsonb;
    v_uuid text;
    v_uuids text[] := '{}';
    v_debit text;
    v_credit text;
    v_amount bigint;
    v_date date;
    v_description text;
begin
    -- validate ledger once
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;

    -- validate input is an array
    if jsonb_typeof(p_transactions) != 'array' then
        raise exception 'Transactions must be a JSON array';
    end if;

    if jsonb_array_length(p_transactions) = 0 then
        return v_uuids;
    end if;

    -- process each transaction
    for v_entry in select * from jsonb_array_elements(p_transactions)
    loop
        -- extract and validate required fields
        v_debit := v_entry->>'debit';
        v_credit := v_entry->>'credit';
        v_amount := (v_entry->>'amount')::bigint;

        if v_debit is null then
            raise exception 'Missing "debit" field in transaction entry';
        end if;

        if v_credit is null then
            raise exception 'Missing "credit" field in transaction entry';
        end if;

        if v_amount is null then
            raise exception 'Missing "amount" field in transaction entry';
        end if;

        -- optional fields
        v_date := coalesce((v_entry->>'date')::date, current_date);
        v_description := v_entry->>'description';

        -- post via ledger.post_transaction (handles all validation, counters, balances)
        select ledger.post_transaction(
            p_ledger_uuid, v_debit, v_credit, v_amount, v_date, v_description
        ) into v_uuid;

        v_uuids := array_append(v_uuids, v_uuid);
    end loop;

    return v_uuids;
end;
$$;

--
-- Name: rebuild_balances(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.rebuild_balances(p_ledger_uuid text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: release(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.release(p_transaction_uuid text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: reserve(text, text, text, bigint, integer, date, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.reserve(p_ledger_uuid text, p_debit_account_uuid text, p_credit_account_uuid text, p_amount bigint, p_timeout_seconds integer DEFAULT 300, p_date date DEFAULT CURRENT_DATE, p_description text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: void(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.void(p_transaction_uuid text, p_reason text DEFAULT 'Voided'::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: post_transaction_checked(bigint, bigint, bigint, bigint, text, text, text); Type: FUNCTION; Schema: utils; Owner: -
--

CREATE FUNCTION utils.post_transaction_checked(p_debit_id bigint, p_credit_id bigint, p_amount bigint, p_txn_id bigint, p_user_data text, p_debit_uuid text, p_credit_uuid text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: post_transaction_fast(bigint, bigint, bigint, bigint, text); Type: FUNCTION; Schema: utils; Owner: -
--

CREATE FUNCTION utils.post_transaction_fast(p_debit_id bigint, p_credit_id bigint, p_amount bigint, p_txn_id bigint, p_user_data text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
$$;

--
-- Name: accounts accounts_ledger_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.accounts
    ADD CONSTRAINT accounts_ledger_id_fkey FOREIGN KEY (ledger_id) REFERENCES data.ledgers(id) ON DELETE CASCADE;

--
-- Name: balances balances_account_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.balances
    ADD CONSTRAINT balances_account_id_fkey FOREIGN KEY (account_id) REFERENCES data.accounts(id);

--
-- Name: balances balances_transaction_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.balances
    ADD CONSTRAINT balances_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES data.transactions(id);

--
-- Name: pending pending_account_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.pending
    ADD CONSTRAINT pending_account_id_fkey FOREIGN KEY (account_id) REFERENCES data.accounts(id);

--
-- Name: pending pending_transaction_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.pending
    ADD CONSTRAINT pending_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES data.transactions(id) ON DELETE CASCADE;

--
-- Name: transaction_log transaction_log_correction_transaction_id_fk; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.transaction_log
    ADD CONSTRAINT transaction_log_correction_transaction_id_fk FOREIGN KEY (correction_transaction_id) REFERENCES data.transactions(id);

--
-- Name: transaction_log transaction_log_original_transaction_id_fk; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.transaction_log
    ADD CONSTRAINT transaction_log_original_transaction_id_fk FOREIGN KEY (original_transaction_id) REFERENCES data.transactions(id);

--
-- Name: transaction_log transaction_log_reversal_transaction_id_fk; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.transaction_log
    ADD CONSTRAINT transaction_log_reversal_transaction_id_fk FOREIGN KEY (reversal_transaction_id) REFERENCES data.transactions(id);

--
-- Name: transactions transactions_credit_account_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.transactions
    ADD CONSTRAINT transactions_credit_account_id_fkey FOREIGN KEY (credit_account_id) REFERENCES data.accounts(id);

--
-- Name: transactions transactions_debit_account_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.transactions
    ADD CONSTRAINT transactions_debit_account_id_fkey FOREIGN KEY (debit_account_id) REFERENCES data.accounts(id);

--
-- Name: transactions transactions_ledger_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: -
--

ALTER TABLE ONLY data.transactions
    ADD CONSTRAINT transactions_ledger_id_fkey FOREIGN KEY (ledger_id) REFERENCES data.ledgers(id) ON DELETE CASCADE;

--
-- Name: accounts accounts_updated_at_tg; Type: TRIGGER; Schema: data; Owner: -
--

CREATE TRIGGER accounts_updated_at_tg BEFORE UPDATE ON data.accounts FOR EACH ROW EXECUTE FUNCTION utils.set_updated_at_fn();

--
-- Name: ledgers ledgers_updated_at_tg; Type: TRIGGER; Schema: data; Owner: -
--

CREATE TRIGGER ledgers_updated_at_tg BEFORE UPDATE ON data.ledgers FOR EACH ROW EXECUTE FUNCTION utils.set_updated_at_fn();

--
-- Name: transactions transactions_updated_at_tg; Type: TRIGGER; Schema: data; Owner: -
--

CREATE TRIGGER transactions_updated_at_tg BEFORE UPDATE ON data.transactions FOR EACH ROW EXECUTE FUNCTION utils.set_updated_at_fn();

--
-- Name: accounts; Type: ROW SECURITY; Schema: data; Owner: -
--

ALTER TABLE data.accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: accounts accounts_policy; Type: POLICY; Schema: data; Owner: -
--

CREATE POLICY accounts_policy ON data.accounts USING ((user_data = utils.get_user())) WITH CHECK ((user_data = utils.get_user()));

--
-- Name: balances; Type: ROW SECURITY; Schema: data; Owner: -
--

ALTER TABLE data.balances ENABLE ROW LEVEL SECURITY;

--
-- Name: balances balances_policy; Type: POLICY; Schema: data; Owner: -
--

CREATE POLICY balances_policy ON data.balances USING ((user_data = utils.get_user())) WITH CHECK ((user_data = utils.get_user()));

--
-- Name: ledgers; Type: ROW SECURITY; Schema: data; Owner: -
--

ALTER TABLE data.ledgers ENABLE ROW LEVEL SECURITY;

--
-- Name: ledgers ledgers_policy; Type: POLICY; Schema: data; Owner: -
--

CREATE POLICY ledgers_policy ON data.ledgers USING ((user_data = utils.get_user())) WITH CHECK ((user_data = utils.get_user()));

--
-- Name: pending; Type: ROW SECURITY; Schema: data; Owner: -
--

ALTER TABLE data.pending ENABLE ROW LEVEL SECURITY;

--
-- Name: pending pending_policy; Type: POLICY; Schema: data; Owner: -
--

CREATE POLICY pending_policy ON data.pending USING ((user_data = utils.get_user())) WITH CHECK ((user_data = utils.get_user()));

--
-- Name: transactions; Type: ROW SECURITY; Schema: data; Owner: -
--

ALTER TABLE data.transactions ENABLE ROW LEVEL SECURITY;

--
-- Name: transactions transactions_policy; Type: POLICY; Schema: data; Owner: -
--

CREATE POLICY transactions_policy ON data.transactions USING ((user_data = utils.get_user())) WITH CHECK ((user_data = utils.get_user()));

--
-- Name: POLICY accounts_policy ON accounts; Type: COMMENT; Schema: data; Owner: -
--

COMMENT ON POLICY accounts_policy ON data.accounts IS 'Ensures that users can only access and modify their own accounts based on the user_data column.';

--
-- Name: POLICY ledgers_policy ON ledgers; Type: COMMENT; Schema: data; Owner: -
--

COMMENT ON POLICY ledgers_policy ON data.ledgers IS 'Ensures that users can only access and modify their own ledgers based on the user_data column.';

--
-- Name: TRIGGER accounts_updated_at_tg ON accounts; Type: COMMENT; Schema: data; Owner: -
--

COMMENT ON TRIGGER accounts_updated_at_tg ON data.accounts IS 'Automatically updates the updated_at timestamp before any update operation on an account.';

--
-- Name: TRIGGER ledgers_updated_at_tg ON ledgers; Type: COMMENT; Schema: data; Owner: -
--

COMMENT ON TRIGGER ledgers_updated_at_tg ON data.ledgers IS 'Automatically updates the updated_at timestamp before any update operation on a ledger.';

--
-- Version stamp
--

INSERT INTO utils.metadata (key, value) VALUES ('version', 'v0.5.0')
    ON CONFLICT (key) DO UPDATE SET value = 'v0.5.0';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop schema if exists ledger cascade;
drop schema if exists utils cascade;
drop schema if exists data cascade;

-- +goose StatementEnd
