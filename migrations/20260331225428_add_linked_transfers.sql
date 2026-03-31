-- +goose Up
-- +goose StatementBegin

-- add link_id to group linked transactions together
alter table data.transactions add column link_id bigint;
create index idx_transactions_link on data.transactions(link_id) where link_id is not null;

-- add visibility to distinguish system accounts from user accounts
alter table data.accounts add column visibility text not null default 'standard';
alter table data.accounts add constraint accounts_visibility_check
    check (visibility in ('standard', 'internal'));

-- update ledger.create_ledger to auto-create a clearing account
create or replace function ledger.create_ledger(
    p_name text,
    p_description text default null
) returns text as $$
declare
    v_name text;
    v_ledger_uuid text;
    v_ledger_id bigint;
begin
    v_name := trim(p_name);
    if v_name is null or v_name = '' then
        raise exception 'Ledger name cannot be empty';
    end if;

    insert into data.ledgers (name, description)
    values (v_name, p_description)
    returning id, uuid into v_ledger_id, v_ledger_uuid;

    -- auto-create internal clearing account for linked transfers
    insert into data.accounts (name, type, ledger_id, user_data, visibility)
    values ('clearing', 'equity', v_ledger_id, utils.get_user(), 'internal');

    return v_ledger_uuid;
end;
$$ language plpgsql security definer;

-- posts multiple linked transactions atomically with a shared link_id.
-- the first transaction's internal id is used as the link_id for the group.
create function ledger.post_linked(
    p_ledger_uuid text,
    p_transactions jsonb
) returns text[] as $$
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
$$ language plpgsql security definer;

-- update get_accounts to optionally hide internal accounts
drop function if exists ledger.get_accounts(text);

create function ledger.get_accounts(
    p_ledger_uuid text,
    p_include_internal boolean default false
) returns table(
    account_uuid text,
    account_name text,
    account_type text,
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
        a.type,
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
    order by a.type, a.name;
end;
$$ language plpgsql stable security definer;

-- update get_history to resolve counterparty through clearing account
create or replace function ledger.get_history(
    p_account_uuid text
) returns table(
    transaction_uuid text,
    date date,
    description text,
    counterparty text,
    amount bigint,
    direction text,
    running_balance bigint
) as $$
declare
    v_account_id bigint;
    v_internal_type text;
    v_ledger_id bigint;
begin
    select a.id, a.internal_type, a.ledger_id
    into v_account_id, v_internal_type, v_ledger_id
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
        -- resolve counterparty: if the other account is the clearing account,
        -- follow the link_id to find the real counterparty
        case
            when cp.visibility != 'standard' and t.link_id is not null then
                -- find the linked transaction's other account
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
        coalesce(
            case when v_internal_type = 'asset_like'
                then b.debits_total - b.credits_total
                else b.credits_total - b.debits_total
            end,
            0
        ) as running_balance
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

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists ledger.post_linked(text, jsonb);
alter table data.accounts drop constraint if exists accounts_visibility_check;
alter table data.accounts drop column if exists visibility;
alter table data.transactions drop column if exists link_id;

-- +goose StatementEnd
