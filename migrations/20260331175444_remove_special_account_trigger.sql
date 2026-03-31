-- +goose Up
-- +goose StatementBegin

-- remove the special account deletion trigger.
-- this is a budgeting concern (protecting Income/Off-budget/Unassigned) that
-- doesn't belong on the data layer. budget.delete_account() will enforce this.
drop trigger if exists trigger_prevent_special_account_deletion on data.accounts;
drop function if exists utils.prevent_special_account_deletion();

-- simplify ledger.delete_ledger — no trigger workaround needed
create or replace function ledger.delete_ledger(
    p_ledger_uuid text
) returns void as $$
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
$$ language plpgsql security definer;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- restore the trigger (from original migration)
create or replace function utils.prevent_special_account_deletion()
    returns trigger as
$$
begin
    raise exception 'Cannot delete special account: %', OLD.name;
    return null;
end;
$$ language plpgsql;

create trigger trigger_prevent_special_account_deletion
    before delete on data.accounts
    for each row
    when (OLD.name in ('Income', 'Off-budget', 'Unassigned') and OLD.type = 'equity')
execute function utils.prevent_special_account_deletion();

-- +goose StatementEnd
