-- +goose Up
-- +goose StatementBegin

-- creates a new budget (ledger) for the current user.
-- default accounts (Income, Off-budget, Unassigned) are created automatically
-- by the trigger_create_default_ledger_accounts trigger.
create function api.create_budget(
    p_name text,
    p_description text default null
) returns text as $$
declare
    v_name text;
    v_budget_uuid text;
begin
    -- validate name
    v_name := trim(p_name);
    if v_name is null or v_name = '' then
        raise exception 'Budget name cannot be empty';
    end if;

    -- insert into data.ledgers
    -- user_data defaults to utils.get_user()
    -- uuid defaults to utils.nanoid(8)
    insert into data.ledgers (name, description)
    values (v_name, p_description)
    returning uuid into v_budget_uuid;

    return v_budget_uuid;
end;
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

drop function if exists api.create_budget(text, text);

-- +goose StatementEnd
