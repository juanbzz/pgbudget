-- +goose Up
-- +goose StatementBegin

-- drop existing functions if they exist (for re-running migration)
drop function if exists api.add_group(text, text, text, integer);
drop function if exists api.get_groups(text);
drop function if exists api.assign_category_to_group(text, text);
drop function if exists api.delete_group(text);

-- creates api function to add a new group
create function api.add_group(
    p_ledger_uuid text,
    p_name text,
    p_description text default null,
    p_sort_order integer default 0
) returns text as $$
declare
    v_ledger_id bigint;
    v_group_id bigint;
    v_group_uuid text;
begin
    -- find the ledger id and validate ownership
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- insert the new group
    insert into data.groups (ledger_id, name, description, sort_order)
    values (v_ledger_id, p_name, p_description, p_sort_order)
    returning id, uuid into v_group_id, v_group_uuid;

    return v_group_uuid;
end;
$$ language plpgsql;

-- creates api function to get all groups for a ledger
create function api.get_groups(
    p_ledger_uuid text
) returns table(
    uuid text,
    name text,
    description text,
    sort_order integer,
    created_at timestamptz
) as $$
declare
    v_ledger_id bigint;
begin
    -- find the ledger id and validate ownership
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- return groups ordered by sort_order, then by name
    return query
    select 
        g.uuid,
        g.name,
        g.description,
        g.sort_order,
        g.created_at
    from data.groups g
    where g.ledger_id = v_ledger_id
      and g.user_data = utils.get_user()
    order by g.sort_order, g.name;
end;
$$ language plpgsql stable security invoker;

-- creates api function to assign a category to a group
create function api.assign_category_to_group(
    p_category_uuid text,
    p_group_uuid text default null
) returns void as $$
declare
    v_category_id bigint;
    v_group_id bigint;
    v_ledger_id bigint;
begin
    -- find the category and validate ownership
    select a.id, a.ledger_id into v_category_id, v_ledger_id
    from data.accounts a
    where a.uuid = p_category_uuid and a.user_data = utils.get_user()
      and a.type = 'equity';  -- ensure it's a category account

    if v_category_id is null then
        raise exception 'Category with UUID % not found for current user', p_category_uuid;
    end if;

    -- if group_uuid is provided, validate it belongs to the same ledger
    if p_group_uuid is not null then
        select g.id into v_group_id
        from data.groups g
        where g.uuid = p_group_uuid 
          and g.ledger_id = v_ledger_id
          and g.user_data = utils.get_user();

        if v_group_id is null then
            raise exception 'Group with UUID % not found for current user in the same ledger', p_group_uuid;
        end if;
    end if;

    -- update the category's group assignment
    update data.accounts
    set group_id = v_group_id,
        updated_at = current_timestamp
    where id = v_category_id;
end;
$$ language plpgsql;

-- creates api function to delete a group (orphans categories)
create function api.delete_group(
    p_group_uuid text
) returns void as $$
declare
    v_group_id bigint;
begin
    -- find the group and validate ownership
    select g.id into v_group_id
    from data.groups g
    where g.uuid = p_group_uuid and g.user_data = utils.get_user();

    if v_group_id is null then
        raise exception 'Group with UUID % not found for current user', p_group_uuid;
    end if;

    -- orphan all categories in this group (set group_id to null)
    update data.accounts
    set group_id = null,
        updated_at = current_timestamp
    where group_id = v_group_id
      and type = 'equity';  -- only affect category accounts

    -- delete the group
    delete from data.groups
    where id = v_group_id;
end;
$$ language plpgsql;

-- updates api.get_budget_totals to support optional group filtering
drop function if exists api.get_budget_totals(text, text);

create function api.get_budget_totals(
    p_ledger_uuid text,
    p_period text default null,
    p_group_uuid text default null
) returns table(
    income bigint,
    income_remaining_from_last_month bigint,
    budgeted bigint,
    left_to_budget bigint
) as $$
declare
    v_start_date date;
    v_end_date date;
    v_prev_month_end date;
    v_income_total bigint;
    v_income_remaining bigint;
    v_total_budgeted bigint;
    v_income_balance bigint;
    v_group_id bigint;
begin
    -- if group filtering is requested, validate the group
    if p_group_uuid is not null then
        select g.id into v_group_id
        from data.groups g
        join data.ledgers l on g.ledger_id = l.id
        where g.uuid = p_group_uuid 
          and l.uuid = p_ledger_uuid
          and g.user_data = utils.get_user();

        if v_group_id is null then
            raise exception 'Group with UUID % not found for current user in ledger %', p_group_uuid, p_ledger_uuid;
        end if;
    end if;

    -- parse period parameter if provided
    if p_period is not null then
        -- validate period format (YYYYMM)
        if p_period !~ '^\d{6}$' then
            raise exception 'Invalid period format. Use YYYYMM (e.g., 202508)';
        end if;
        
        -- extract year and month to create date range
        v_start_date := (p_period || '01')::date;  -- first day of month
        v_end_date := (v_start_date + interval '1 month - 1 day')::date;  -- last day of month
        
        -- if end date is in the future, use today instead
        if v_end_date > current_date then
            v_end_date := current_date;
        end if;
        
        -- calculate previous month end for income remaining calculation
        v_prev_month_end := v_start_date - interval '1 day';
    end if;
    
    -- get total income for the period (income is not group-specific)
    if p_group_uuid is null then
        v_income_total := utils.get_income_total(p_ledger_uuid, utils.get_user(), v_start_date, v_end_date);
    else
        v_income_total := 0;  -- income is not attributed to groups
    end if;
    
    -- get income remaining from last month (only for month view and when not filtering by group)
    if p_period is not null and p_group_uuid is null then
        -- get income account balance as of end of previous month
        select coalesce(
            (select utils.get_account_balance(
                (select id from data.ledgers where uuid = p_ledger_uuid),
                a.id
            ) - utils.get_income_total(p_ledger_uuid, utils.get_user(), v_start_date, null)), 0
        ) into v_income_remaining
        from data.accounts a
        where a.ledger_id = (select id from data.ledgers where uuid = p_ledger_uuid)
          and a.user_data = utils.get_user()
          and a.name = 'Income'
          and a.type = 'equity';
    else
        v_income_remaining := 0;
    end if;
    
    -- calculate total budgeted (sum of category budgeted amounts for the period, optionally filtered by group)
    if p_group_uuid is null then
        -- all categories
        select coalesce(sum(bs.budgeted), 0) into v_total_budgeted
        from utils.get_budget_status(p_ledger_uuid, utils.get_user(), v_start_date, v_end_date) bs;
    else
        -- only categories in the specified group
        select coalesce(sum(bs.budgeted), 0) into v_total_budgeted
        from utils.get_budget_status(p_ledger_uuid, utils.get_user(), v_start_date, v_end_date) bs
        join data.accounts c on c.uuid = bs.account_uuid
        where c.group_id = v_group_id
          and c.type = 'equity';  -- ensure we're only looking at category accounts
    end if;
    
    -- get current income account balance (left to budget) - only when not filtering by group
    if p_group_uuid is null then
        select coalesce(utils.get_account_balance(
            (select id from data.ledgers where uuid = p_ledger_uuid),
            a.id
        ), 0) into v_income_balance
        from data.accounts a
        where a.ledger_id = (select id from data.ledgers where uuid = p_ledger_uuid)
          and a.user_data = utils.get_user()
          and a.name = 'Income'
          and a.type = 'equity';
    else
        v_income_balance := 0;  -- not applicable when filtering by group
    end if;
    
    -- return the totals
    return query
    select 
        v_income_total as income,
        v_income_remaining as income_remaining_from_last_month,
        v_total_budgeted as budgeted,
        v_income_balance as left_to_budget;
end;
$$ language plpgsql;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- restore original budget totals function
drop function if exists api.get_budget_totals(text, text, text);

create function api.get_budget_totals(
    p_ledger_uuid text,
    p_period text default null
) returns table(
    income bigint,
    income_remaining_from_last_month bigint,
    budgeted bigint,
    left_to_budget bigint
) as $$
declare
    v_start_date date;
    v_end_date date;
    v_prev_month_end date;
    v_income_total bigint;
    v_income_remaining bigint;
    v_total_budgeted bigint;
    v_income_balance bigint;
begin
    -- parse period parameter if provided
    if p_period is not null then
        -- validate period format (YYYYMM)
        if p_period !~ '^\d{6}$' then
            raise exception 'Invalid period format. Use YYYYMM (e.g., 202508)';
        end if;
        
        -- extract year and month to create date range
        v_start_date := (p_period || '01')::date;  -- first day of month
        v_end_date := (v_start_date + interval '1 month - 1 day')::date;  -- last day of month
        
        -- if end date is in the future, use today instead
        if v_end_date > current_date then
            v_end_date := current_date;
        end if;
        
        -- calculate previous month end for income remaining calculation
        v_prev_month_end := v_start_date - interval '1 day';
    end if;
    
    -- get total income for the period
    v_income_total := utils.get_income_total(p_ledger_uuid, utils.get_user(), v_start_date, v_end_date);
    
    -- get income remaining from last month (only for month view)
    if p_period is not null then
        -- get income account balance as of end of previous month
        select coalesce(
            (select utils.get_account_balance(
                (select id from data.ledgers where uuid = p_ledger_uuid),
                a.id
            ) - utils.get_income_total(p_ledger_uuid, utils.get_user(), v_start_date, null)), 0
        ) into v_income_remaining
        from data.accounts a
        where a.ledger_id = (select id from data.ledgers where uuid = p_ledger_uuid)
          and a.user_data = utils.get_user()
          and a.name = 'Income'
          and a.type = 'equity';
    else
        v_income_remaining := 0;
    end if;
    
    -- calculate total budgeted (sum of all category budgeted amounts for the period)
    select coalesce(sum(bs.budgeted), 0) into v_total_budgeted
    from utils.get_budget_status(p_ledger_uuid, utils.get_user(), v_start_date, v_end_date) bs;
    
    -- get current income account balance (left to budget)
    select coalesce(utils.get_account_balance(
        (select id from data.ledgers where uuid = p_ledger_uuid),
        a.id
    ), 0) into v_income_balance
    from data.accounts a
    where a.ledger_id = (select id from data.ledgers where uuid = p_ledger_uuid)
      and a.user_data = utils.get_user()
      and a.name = 'Income'
      and a.type = 'equity';
    
    -- return the totals
    return query
    select 
        v_income_total as income,
        v_income_remaining as income_remaining_from_last_month,
        v_total_budgeted as budgeted,
        v_income_balance as left_to_budget;
end;
$$ language plpgsql;

-- drop group management functions
drop function if exists api.delete_group(uuid);
drop function if exists api.assign_category_to_group(uuid, uuid);
drop function if exists api.get_groups(uuid);
drop function if exists api.add_group(uuid, text, text, integer);

-- +goose StatementEnd
