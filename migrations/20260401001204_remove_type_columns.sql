-- +goose Up
-- +goose StatementBegin

-- rewrite ledger.create_ledger — just create the ledger row, no auto accounts
create or replace function ledger.create_ledger(
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

-- rewrite ledger.create_account — remove p_type parameter
-- drop old signature first (had type parameter)
drop function if exists ledger.create_account(text, text, text, text, boolean, boolean);

create function ledger.create_account(
    p_ledger_uuid text,
    p_name text,
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
$$ language plpgsql security definer;

-- rewrite ledger.get_balance — return raw counters (return type changed, must drop first)
drop function if exists ledger.get_balance(text);
create function ledger.get_balance(
    p_account_uuid text
) returns table(debits_total bigint, credits_total bigint) as $$
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
$$ language plpgsql stable security definer;

-- rewrite ledger.get_balances — return raw counters per account
drop function if exists ledger.get_balances(text);

create function ledger.get_balances(
    p_ledger_uuid text
) returns table(
    account_uuid text,
    account_name text,
    debits_total bigint,
    credits_total bigint
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
        a.debits_total,
        a.credits_total
    from data.accounts a
    where a.ledger_id = v_ledger_id
      and a.user_data = utils.get_user()
    order by a.name;
end;
$$ language plpgsql stable security definer;

-- rewrite ledger.get_history — return raw counters (return type changed, must drop first)
drop function if exists ledger.get_history(text);
create function ledger.get_history(
    p_account_uuid text
) returns table(
    transaction_uuid text,
    date date,
    description text,
    counterparty text,
    amount bigint,
    direction text,
    debits_total bigint,
    credits_total bigint
) as $$
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
$$ language plpgsql stable security definer;

-- rewrite ledger.get_accounts — remove account_type from return
drop function if exists ledger.get_accounts(text, boolean);

create function ledger.get_accounts(
    p_ledger_uuid text,
    p_include_internal boolean default false
) returns table(
    account_uuid text,
    account_name text,
    description text,
    visibility text,
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

-- drop the internal_type trigger and function
drop trigger if exists accounts_set_internal_type_tg on data.accounts;
drop function if exists utils.set_account_internal_type_fn();

-- drop columns and constraints
alter table data.accounts drop constraint if exists accounts_internal_type_check;
alter table data.accounts drop constraint if exists accounts_type_check;
alter table data.accounts drop column if exists internal_type;
alter table data.accounts drop column if exists type;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
select 'down migration not supported — type/internal_type columns and function signatures changed';
-- +goose StatementEnd
