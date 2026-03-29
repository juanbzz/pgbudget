-- +goose Up
-- +goose StatementBegin

-- creates a new account in a budget.
-- accepts budgeting types (bank, credit_card, cash) or accounting types
-- (asset, liability). rejects equity (use api.add_category instead).
create function api.add_account(
    p_budget_uuid text,
    p_name text,
    p_type text,
    p_description text default null
) returns text as $$
declare
    v_name text;
    v_internal_type text;
    v_ledger_id bigint;
    v_account_uuid text;
begin
    -- validate name
    v_name := trim(p_name);
    if v_name is null or v_name = '' then
        raise exception 'Account name cannot be empty';
    end if;

    -- map type to internal accounting type
    case p_type
        when 'bank', 'cash', 'asset' then
            v_internal_type := 'asset';
        when 'credit_card', 'liability' then
            v_internal_type := 'liability';
        else
            raise exception 'Invalid account type: %. Use bank, credit_card, cash, asset, or liability', p_type;
    end case;

    -- find the budget and validate ownership
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_budget_uuid and l.user_data = utils.get_user();

    if v_ledger_id is null then
        raise exception 'Budget with UUID % not found for current user', p_budget_uuid;
    end if;

    -- insert the account
    -- internal_type (asset_like/liability_like) is set by accounts_set_internal_type_tg trigger
    insert into data.accounts (name, type, description, ledger_id, user_data)
    values (v_name, v_internal_type, p_description, v_ledger_id, utils.get_user())
    returning uuid into v_account_uuid;

    return v_account_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists api.add_account(text, text, text, text);

-- +goose StatementEnd
