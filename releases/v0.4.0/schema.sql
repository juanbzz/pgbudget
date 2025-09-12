-- pgbudget v0.4.0 - Complete Schema
-- Generated on Fri Sep 12 17:59:36 CDT 2025
-- For fresh installations

-- Create schemas
CREATE SCHEMA IF NOT EXISTS data;
CREATE SCHEMA IF NOT EXISTS utils;
CREATE SCHEMA IF NOT EXISTS api;

-- From: 20250102210201_add_schemas.sql

-- holds data tables
create schema if not exists data;

-- holds read/write functions
create schema if not exists api;

-- holds utility functions unrelated to the data tables
create schema if not exists utils;



-- From: 20250202204922_add_nanoid.sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- The `nanoid()` function generates s compact, URL-friendly unique identifier.
-- Based on the given size and alphabet, it creates s randomized string that's ideal for
-- use-cases requiring small, unpredictable IDs (e.g., URL shorteners, generated file names, etc.).
-- While it comes with s default configuration, the function is designed to be flexible,
-- allowing for customization to meet specific needs.
DROP FUNCTION IF EXISTS utils.nanoid(int, text, float);
CREATE OR REPLACE FUNCTION utils.nanoid(
    size int DEFAULT 21, -- The number of symbols in the NanoId String. Must be greater than 0.
    alphabet text DEFAULT '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ', -- The symbols used in the NanoId String. Must contain between 1 and 255 symbols.
    additionalBytesFactor float DEFAULT 1.6 -- The additional bytes factor used for calculating the step size. Must be equal or greater than 1.
)
    RETURNS text -- A randomly generated NanoId String
    LANGUAGE plpgsql
    VOLATILE
    PARALLEL SAFE
    -- Uncomment the following line if you have superuser privileges
    -- LEAKPROOF
AS
$$
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

-- Generates an optimized random string of s specified size using the given alphabet, mask, and step.
-- This optimized version is designed for higher performance and lower memory overhead.
-- No checks are performed! Use it only if you really know what you are doing.
DROP FUNCTION IF EXISTS utils.nanoid_optimized(int, text, int, int);
CREATE OR REPLACE FUNCTION utils.nanoid_optimized(
    size int, -- The desired length of the generated string.
    alphabet text, -- The set of characters to choose from for generating the string.
    mask int, -- The mask used for mapping random bytes to alphabet indices. Should be `(2^n) - 1` where `n` is s power of 2 less than or equal to the alphabet size.
    step int -- The number of random bytes to generate in each iteration. A larger value may speed up the function but increase memory usage.
)
    RETURNS text -- A randomly generated NanoId String
    LANGUAGE plpgsql
    VOLATILE
    PARALLEL SAFE
    -- Uncomment the following line if you have superuser privileges
    -- LEAKPROOF
AS
$$
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


-- From: 20250506162103_add_global_utils.sql

create or replace function utils.set_updated_at_fn()
    returns trigger as
$$
begin
    new.updated_at := current_timestamp;
    return new;
end;
$$ language plpgsql;


create or replace function utils.get_user() returns text as
$$
begin
    -- Try to get application user from session variable first
    -- This allows the Go microservice to set user context per request
    -- Falls back to current_user for tests and direct database access
    return coalesce(
        current_setting('app.current_user_id', true),
        current_user
    );
end;
$$ language plpgsql stable;




-- From: 20250506162508_add_ledgers_table.sql

create table data.ledgers
(
    id          bigint generated always as identity primary key,
    uuid        text        not null default utils.nanoid(8),

    created_at  timestamptz not null default current_timestamp,
    updated_at  timestamptz not null default current_timestamp,

    name        text        not null,
    description text,
    metadata    jsonb,

    user_data   text        not null default utils.get_user(),

    constraint ledgers_uuid_unique unique (uuid),
    constraint ledgers_name_user_unique unique (name, user_data),
    constraint ledgers_name_length_check check (char_length(name) <= 255),
    constraint ledgers_user_data_length_check check (char_length(user_data) <= 255),
    constraint ledgers_description_length_check check (char_length(description) <= 255)
);

-- enable RLS
alter table data.ledgers
    enable row level security;

create policy ledgers_policy on data.ledgers
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

comment on policy ledgers_policy on data.ledgers is 'Ensures that users can only access and modify their own ledgers based on the user_data column.';



-- From: 20250506162515_add_ledgers_utils.sql

-- Function to create default accounts for a new ledger
create or replace function utils.create_default_ledger_accounts()
    returns trigger as
$$
begin
    -- create income account (Equity type)
    insert into data.accounts (ledger_id, user_data, name, type, internal_type, created_at, updated_at)
    values (NEW.id, NEW.user_data, 'Income', 'equity', 'liability_like', current_timestamp, current_timestamp);

    -- create Off-budget account (Equity type)
    insert into data.accounts (ledger_id, user_data, name, type, internal_type, created_at, updated_at)
    values (NEW.id, NEW.user_data,'Off-budget', 'equity', 'liability_like', current_timestamp, current_timestamp);

    -- create Unassigned account (Equity type)
    insert into data.accounts (ledger_id, user_data, name, type, internal_type, created_at, updated_at)
    values (NEW.id, NEW.user_data, 'Unassigned', 'equity', 'liability_like', current_timestamp, current_timestamp);

    return new;
end;
$$ language plpgsql;

comment on function utils.create_default_ledger_accounts() is 'Trigger function to automatically create default accounts (Income, Off-budget, Unassigned) when a new ledger is inserted into data.ledgers.';

-- Function to prevent deletion of special accounts (acts on data.accounts)
create or replace function utils.prevent_special_account_deletion()
    returns trigger as
$$
begin
    raise exception 'Cannot delete special account: %', OLD.name;
    RETURN NULL; -- For BEFORE trigger, returning NULL cancels the operation.
end;
$$ language plpgsql;

comment on function utils.prevent_special_account_deletion() is 'Trigger function to prevent the deletion of special accounts (Income, Off-budget, Unassigned).';



-- From: 20250506162524_add_ledgers_views.sql

create or replace view api.ledgers with (security_invoker = true) as
select a.uuid,
       a.name,
       a.description,
       a.metadata,
       a.user_data
  from data.ledgers a;

comment on view api.ledgers is 'Provides a public, RLS-aware view of ledgers. Excludes internal ID and raw audit timestamps (created_at, updated_at).';

comment on view api.ledgers is 'Grants all permissions (SELECT, INSERT, UPDATE, DELETE) on the api.ledgers view to the pgb_web_user role. PostgREST can handle mutations on simple views like this directly.';



-- From: 20250506162528_add_ledgers_triggers.sql

-- Trigger function to set the updated_at timestamp
create trigger ledgers_updated_at_tg
    before update
    on data.ledgers
    for each row
execute procedure utils.set_updated_at_fn();

comment on trigger ledgers_updated_at_tg on data.ledgers is 'Automatically updates the updated_at timestamp before any update operation on a ledger.';



-- From: 20250506163248_add_accounts_table.sql

-- creates the accounts table to store different types of accounts for ledgers.
create table data.accounts
(
    id            bigint generated always as identity primary key,
    uuid          text        not null default utils.nanoid(8),

    created_at    timestamptz not null default current_timestamp,
    updated_at    timestamptz not null default current_timestamp,

    name          text        not null,
    description   text,
    type          text        not null,
    internal_type text        not null,
    metadata      jsonb,
    user_data     text        not null default utils.get_user(),

    -- links the account to a ledger. accounts are deleted if the parent ledger is deleted.
    ledger_id     bigint      not null references data.ledgers (id) on delete cascade,

    -- constraints
    constraint accounts_uuid_unique unique (uuid),
    constraint accounts_name_ledger_unique unique (name, ledger_id, user_data),
    constraint accounts_name_length_check check (char_length(name) <= 255),
    constraint accounts_user_data_length_check check (char_length(user_data) <= 255),
    constraint accounts_description_length_check check (char_length(description) <= 255),
    constraint accounts_type_check check (
        type in ('asset', 'liability', 'equity', 'revenue', 'expense')
    ),
    -- ensures 'internal_type' is consistent with 'type'.
    -- 'asset' and 'expense' accounts are 'asset_like' (debits increase balance).
    -- 'liability', 'equity', and 'revenue' accounts are 'liability_like' (credits increase balance).
    constraint accounts_internal_type_check check (
        (type = 'asset' and internal_type = 'asset_like') or
        (type = 'expense' and internal_type = 'asset_like') or
        (type = 'liability' and internal_type = 'liability_like') or
        (type = 'equity' and internal_type = 'liability_like') or
        (type = 'revenue' and internal_type = 'liability_like')
    )
);

-- enables row level security (rls) on the data.accounts table.
alter table data.accounts
    enable row level security;

-- creates an rls policy on data.accounts to ensure users can only access and modify their own accounts.
create policy accounts_policy on data.accounts
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

comment on policy accounts_policy on data.accounts is 'Ensures that users can only access and modify their own accounts based on the user_data column.';



-- From: 20250506163256_add_accounts_utils.sql

-- creates a trigger function in the utils schema to set internal_type based on account type.
create or replace function utils.set_account_internal_type_fn()
    returns trigger as
$$
begin
    -- determine internal_type based on the account's 'type'.
    -- 'asset' and 'expense' types are 'asset_like' (debits increase balance).
    -- 'liability', 'equity', and 'revenue' types are 'liability_like' (credits increase balance).
    if new.type = 'asset' or new.type = 'expense' then
        new.internal_type := 'asset_like';
    else
        new.internal_type := 'liability_like';
    end if;

    return new;
end;
$$ language plpgsql;

comment on function utils.set_account_internal_type_fn() is 'Trigger function to automatically set the `internal_type` of an account based on its `type` before insert or update.';

-- Trigger function to handle inserts into the api.accounts view
create or replace function utils.accounts_insert_single_fn() returns trigger as
$$
declare
    v_ledger_id   bigint;
    v_user_data   text := utils.get_user(); -- Explicitly capture the current user context
begin
    -- get the ledger_id based on the provided ledger_uuid
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid
       and l.user_data = v_user_data; -- Ensure user (from v_user_data) owns the ledger

    -- Raise exception if the ledger is not found for the current user
    if v_ledger_id is null then
        -- Include the user context in the error for better debugging
        raise exception 'Ledger with UUID % not found for current user %', NEW.ledger_uuid, v_user_data;
    end if;

    -- insert the account into the base data.accounts table
    -- The internal_type will be set automatically by the accounts_set_internal_type_tg trigger
    -- The user_data will be set automatically by the default value on the table
       insert into data.accounts (name, type, description, metadata, ledger_id)
       values (NEW.name,
               NEW.type,
               NEW.description,
               NEW.metadata,
               v_ledger_id)
-- Only return the uuid and user_data as these are the only fields that aren't already in NEW
    returning uuid, user_data into
        new.uuid, new.user_data;

    -- The ledger_uuid is already part of the NEW record passed to the trigger,
    -- so it doesn't need to be explicitly returned or set here.

    return new; -- Return the NEW record populated with generated values
end;
$$ language plpgsql security definer; -- Security definer to allow controlled insert


-- ADD THE NEW UPDATE TRIGGER FUNCTION HERE
-- trigger function for handling INSTEAD OF UPDATE on api.accounts view
create or replace function utils.accounts_update_single_fn()
returns trigger as
$$
declare
    v_ledger_id int;
    v_account_id int;
    v_user_data text := utils.get_user(); -- Get current user context
begin
    -- Optimize queries based on whether ledger is changing
    if NEW.ledger_uuid is not null and NEW.ledger_uuid <> OLD.ledger_uuid then
        -- Only query when ledger is actually changing
        select l.id into v_ledger_id
          from data.ledgers l
         where l.uuid = NEW.ledger_uuid and l.user_data = v_user_data;
        
        if v_ledger_id is null then
            raise exception 'Target ledger with UUID % not found for current user', NEW.ledger_uuid;
        end if;
        
        -- Get account_id separately
        select a.id into v_account_id
          from data.accounts a
         where a.uuid = OLD.uuid and a.user_data = v_user_data;
        
        if v_account_id is null then
            raise exception 'Account with UUID % not found for current user to update', OLD.uuid;
        end if;
    else
        -- Use a join to get both account_id and ledger_id in one query when ledger isn't changing
        select a.id, a.ledger_id into v_account_id, v_ledger_id
          from data.accounts a
         where a.uuid = OLD.uuid and a.user_data = v_user_data;
        
        if v_account_id is null then
            raise exception 'Account with UUID % not found for current user to update', OLD.uuid;
        end if;
    end if;

    -- Update the underlying data.accounts table
    update data.accounts
       set name = coalesce(NEW.name, OLD.name),
           type = coalesce(NEW.type, OLD.type),
           description = coalesce(NEW.description, OLD.description),
           metadata = coalesce(NEW.metadata, OLD.metadata),
           ledger_id = v_ledger_id -- This uses the resolved v_ledger_id
           -- user_data is NOT updated here to prevent ownership changes.
           -- updated_at is handled by the accounts_updated_at_tg trigger on data.accounts
     where id = v_account_id;

    -- Populate NEW record for returning from the view operation.
    NEW.uuid := OLD.uuid; -- UUID does not change
    -- If NEW.ledger_uuid was not provided in the update, it will be OLD.ledger_uuid.
    -- If it was provided, it's already NEW.ledger_uuid.
    -- The user_data is from the original record and should not be changed by this update.
    NEW.user_data := OLD.user_data;
    -- The other fields (name, type, description, metadata) in NEW are already populated
    -- by the values from the UPDATE statement on the view.

    return NEW;
end;
$$ language plpgsql volatile security definer;

-- Create a trigger function to handle DELETE operations on the api.accounts view
create or replace function utils.accounts_delete_single_fn()
returns trigger as
$$
declare
    v_account_id int;
    v_user_data text := utils.get_user();
    v_is_special boolean;
begin
    -- Check if this is a special account that shouldn't be deleted
    select (a.name in ('Income', 'Off-budget', 'Unassigned') and a.type = 'equity') into v_is_special
      from data.accounts a
     where a.uuid = OLD.uuid and a.user_data = v_user_data;
    
    if v_is_special then
        raise exception 'Cannot delete special account: %', OLD.name;
    end if;

    -- Get the internal ID of the account to delete
    select a.id into v_account_id
      from data.accounts a
     where a.uuid = OLD.uuid and a.user_data = v_user_data;
    
    if v_account_id is null then
        raise exception 'Account with UUID % not found for current user to delete', OLD.uuid;
    end if;

    -- Delete the account
    delete from data.accounts where id = v_account_id;
    
    return OLD;
end;
$$ language plpgsql volatile security definer;



-- From: 20250506163304_add_accounts_views.sql

-- API view for accounts, joining with ledgers to expose ledger_uuid
create or replace view api.accounts with (security_invoker = true) as
select a.uuid,
       a.name,
       a.type,
       a.description,
       a.metadata,
       a.user_data,
       l.uuid::text as ledger_uuid -- Get ledger_uuid from the joined data.ledgers table
  from data.accounts a
  join data.ledgers l on a.ledger_id = l.id; -- Join accounts with ledgers



-- From: 20250506163308_add_accounts_triggers.sql

-- Trigger to run the function when a new ledger is created
create trigger trigger_create_default_ledger_accounts
    after insert
    on data.ledgers
    for each row
execute function utils.create_default_ledger_accounts();

comment on trigger trigger_create_default_ledger_accounts on data.ledgers is 'After inserting a new ledger, automatically creates associated default accounts.';

-- Constraint to prevent duplicate special accounts per ledger (acts on data.accounts)
create unique index if not exists unique_special_accounts_per_ledger
    on data.accounts (ledger_id, name)
    where name in ('Income', 'Off-budget', 'Unassigned') and type = 'equity';

comment on index data.unique_special_accounts_per_ledger is 'Ensures that special account names (Income, Off-budget, Unassigned) are unique per ledger for equity type accounts.';

-- Trigger to prevent deletion of special accounts (acts on data.accounts)
create trigger trigger_prevent_special_account_deletion
    before delete
    on data.accounts
    for each row
    when (OLD.name in ('Income', 'Off-budget', 'Unassigned') and OLD.type = 'equity')
execute function utils.prevent_special_account_deletion();

comment on trigger trigger_prevent_special_account_deletion on data.accounts is 'Prevents deletion of special equity accounts (Income, Off-budget, Unassigned).';

-- creates a trigger to automatically update the updated_at timestamp before any update operation on an account.
create trigger accounts_updated_at_tg
    before update
    on data.accounts
    for each row
execute procedure utils.set_updated_at_fn();

comment on trigger accounts_updated_at_tg on data.accounts is 'Automatically updates the updated_at timestamp before any update operation on an account.';

-- creates a trigger to automatically set internal_type before insert on data.accounts.
-- Note: The file has "before insert", but the comment in utils says "before insert or update".
-- For consistency with the utils function, let's make it "before insert or update".
-- If it was intentionally only "before insert", this is a change.
-- Based on utils.set_account_internal_type_fn, it should handle updates too if type changes.
create trigger accounts_set_internal_type_tg -- Name matches existing
    before insert or update -- Ensuring it covers updates if type changes
    on data.accounts
    for each row
execute procedure utils.set_account_internal_type_fn();

comment on trigger accounts_set_internal_type_tg on data.accounts is 'Automatically sets the `internal_type` column based on the `type` column before an account is inserted or updated.';

-- Trigger to route INSERT operations on the view to the trigger function
create trigger accounts_insert_tg
    instead of insert
    on api.accounts
    for each row
execute function utils.accounts_insert_single_fn(); -- Correctly calls existing function

-- ADD THE NEW UPDATE TRIGGER HERE
-- Trigger for api.accounts view (handles updates)
create trigger accounts_update_tg
    instead of update
    on api.accounts
    for each row
execute procedure utils.accounts_update_single_fn();


-- Trigger for api.accounts view (handles deletes)
create trigger accounts_delete_tg
    instead of delete
    on api.accounts
    for each row
execute procedure utils.accounts_delete_single_fn();



-- From: 20250506163310_add_category_utils.sql

-- function to create a new category account (internal)
-- takes ledger uuid, category name, and user_data
-- returns the full data.accounts record for the new category
create or replace function utils.add_category(
    p_ledger_uuid text,
    p_name text,
    p_user_data text = utils.get_user()
) returns data.accounts as -- Return the full account record
$$
declare
    v_ledger_id   int;
    v_account_record data.accounts;
begin
    -- find the ledger ID for the specified UUID and user
    -- ensures the user owns the ledger
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    -- raise exception if ledger not found for the user
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- validate the category name is not empty (trim once)
    p_name := trim(p_name);
    if p_name is null or p_name = '' then
        raise exception 'Category name cannot be empty';
    end if;

    -- create the category account (equity type, liability_like behavior)
    -- associate it with the user using user_data
       insert into data.accounts (ledger_id, name, type, internal_type, user_data)
       values (v_ledger_id, p_name, 'equity', 'liability_like', p_user_data)
    returning * into v_account_record; -- return the newly created account record

    return v_account_record;
end;
$$ language plpgsql security definer; -- runs with definer privileges for controlled data access

-- function to create multiple categories at once (internal)
-- takes ledger uuid, array of category names, and user_data
-- returns a set of data.accounts records for the new categories
create or replace function utils.add_categories(
    p_ledger_uuid text,
    p_names text[],
    p_user_data text = utils.get_user()
) returns setof data.accounts as
$$
declare
    v_ledger_id int;
    v_name text;
    v_account_record data.accounts;
begin
    -- find the ledger ID for the specified UUID and user
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    -- raise exception if ledger not found for the user
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- Process each category name
    foreach v_name in array p_names
    loop
        -- Skip empty names after trimming
        v_name := trim(v_name);
        if v_name = '' then
            continue;
        end if;

        -- Create the category account
        begin
            insert into data.accounts (ledger_id, name, type, internal_type, user_data)
            values (v_ledger_id, v_name, 'equity', 'liability_like', p_user_data)
            returning * into v_account_record;
            
            -- Return this record
            return next v_account_record;
        exception
            when unique_violation then
                -- Re-raise the exception to be consistent with single category creation
                raise exception 'Category with name "%" already exists in this ledger', v_name;
        end;
    end loop;

    return;
end;
$$ language plpgsql security definer;


-- function to find a category by name in a ledger (internal utility)
-- takes ledger uuid, category name, and user_data
-- returns the UUID of the found category account
create or replace function utils.find_category(
    p_ledger_uuid text,
    p_category_name text,
    p_user_data text = utils.get_user()
) returns text as -- Return UUID
$$
declare
    v_ledger_id int;
    v_category_uuid text;
begin
    -- find the ledger ID for the specified UUID and user
    -- ensures the user owns the ledger
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    -- raise exception if ledger not found for the user
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- find the category account UUID for this ledger, user, and name
    -- ensures the account is of type 'equity' (a category)
    select a.uuid
      into v_category_uuid
      from data.accounts a
     where a.ledger_id = v_ledger_id
       and a.user_data = p_user_data
       and a.name = p_category_name
       and a.type = 'equity';

    -- return the found UUID (will be null if not found)
    return v_category_uuid;
end;
$$ language plpgsql stable security definer; -- runs with definer privileges, read-only



-- From: 20250506163320_add_category_triggers.sql
SELECT 'up SQL query';


-- From: 20250506163325_add_category_views.sql

-- function to create a new category account (public API)
-- takes ledger uuid and category name
-- returns a record matching the structure of api.accounts view
create or replace function api.add_category(
    ledger_uuid text,
    name text -- Keep user-friendly input parameter name
) returns setof api.accounts as -- Use SETOF <view_name>
$$
declare
    v_util_result data.accounts; -- holds the result from the utility function
begin
    -- Call the internal utility function to perform the insertion
    -- implicitly uses the current user's context via utils.get_user() default
    v_util_result := utils.add_category(ledger_uuid, name);

    -- Return the newly created account by querying the corresponding API view
    -- This ensures the output matches the view definition exactly.
    return query
        select *
          from api.accounts a -- Query the view
         where a.uuid = v_util_result.uuid; -- Filter for the created account UUID

end;
$$ language plpgsql volatile security invoker; -- runs with invoker privileges, relies on utils function for security

-- API function for batch category creation
-- takes ledger uuid and array of category names
-- returns a set of records matching the structure of api.accounts view
create or replace function api.add_categories(
    ledger_uuid text,
    names text[]
) returns setof api.accounts as
$$
declare
    v_account_record record;
begin
    -- Call the utility function and return results through the API view
    for v_account_record in select * from utils.add_categories(ledger_uuid, names)
    loop
        -- Return each account through the API view
        return query
            select *
              from api.accounts a
             where a.uuid = v_account_record.uuid;
    end loop;

    return;
end;
$$ language plpgsql volatile security invoker;

-- Grant execute permission to web user



-- From: 20250506165219_add_transactions_table.sql

create table data.transactions
(
    id                bigint generated always as identity primary key,
    uuid              text        not null default utils.nanoid(8),

    created_at        timestamptz not null default current_timestamp,
    updated_at        timestamptz not null default current_timestamp,

    amount            bigint      not null default 0,
    date              date,
    description       text,
    metadata          jsonb,
    status            text        not null default 'posted',

    credit_account_id bigint      not null references data.accounts (id),
    debit_account_id  bigint      not null references data.accounts (id),

    deleted_at        timestamptz default null, -- For soft deletes
    user_data         text        not null default utils.get_user(),

    -- fks
    ledger_id         bigint      not null references data.ledgers (id) on delete cascade,

    constraint transactions_uuid_unique unique (uuid),
    constraint transactions_amount_positive check (amount >= 0),
    constraint transactions_different_accounts check (credit_account_id != debit_account_id),
    constraint transactions_description_length_check check (char_length(description) < 255),
    constraint transactions_user_data_length_check check (char_length(user_data) < 255),
    constraint transactions_status_check check (status in ('pending', 'posted'))
);

-- enable RLS
alter table data.transactions
    enable row level security;

create policy transactions_policy on data.transactions
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());



-- From: 20250506165222_add_transactions_utils.sql

-- function to add a transaction
-- this function abstract the underlying logic of adding a transaction into a more user-friendly API
create or replace function utils.add_transaction(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_type text, -- 'inflow' or 'outflow'
    p_amount bigint,
    p_account_uuid text, -- the bank account or credit card
    p_category_uuid text = null, -- the category, now optional
    p_user_data text = utils.get_user() -- Add user context parameter
) returns int as
$$
declare
    v_ledger_id             int;
    v_account_id            int;
    v_account_internal_type text;
    v_category_id           int;
    v_transaction_id        int;
    v_debit_account_id      int;
    v_credit_account_id     int;
begin
    -- validate inputs early for fast failure
    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive: %', p_amount;
    end if;

    if p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', p_type;
    end if;

    -- find the ledger_id from uuid and validate ownership
    select l.id into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- find the account_id and internal_type in one query
    select a.id, a.internal_type 
      into v_account_id, v_account_internal_type
      from data.accounts a
     where a.uuid = p_account_uuid 
       and a.ledger_id = v_ledger_id
       and a.user_data = p_user_data;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger % for current user', 
                       p_account_uuid, p_ledger_uuid;
    end if;

    -- handle category lookup
    if p_category_uuid is null then
        -- find the "Unassigned" category directly
        select a.id into v_category_id
          from data.accounts a
         where a.ledger_id = v_ledger_id
           and a.user_data = p_user_data
           and a.name = 'Unassigned'
           and a.type = 'equity';
           
        if v_category_id is null then
            raise exception 'Could not find "Unassigned" category in ledger % for current user', 
                           p_ledger_uuid;
        end if;
    else
        -- find the specified category
        select a.id into v_category_id
          from data.accounts a
         where a.uuid = p_category_uuid 
           and a.ledger_id = v_ledger_id
           and a.user_data = p_user_data;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger % for current user', 
                           p_category_uuid, p_ledger_uuid;
        end if;
    end if;

    -- determine debit and credit accounts based on account type and transaction type
    -- following double-entry accounting principles from SPEC.md
    case 
        when v_account_internal_type = 'asset_like' and p_type = 'inflow' then
            -- inflow to asset: debit asset (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        when v_account_internal_type = 'asset_like' and p_type = 'outflow' then
            -- outflow from asset: debit category (decrease), credit asset (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and p_type = 'inflow' then
            -- inflow to liability: debit category (decrease), credit liability (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and p_type = 'outflow' then
            -- outflow from liability: debit liability (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        else
            raise exception 'Unsupported combination: account_type=% and transaction_type=%', 
                           v_account_internal_type, p_type;
    end case;

    -- insert the transaction and return the new id
    insert into data.transactions (
        ledger_id,
        date,
        description,
        debit_account_id,
        credit_account_id,
        amount,
        user_data
    )
    values (
        v_ledger_id,
        p_date,
        p_description,
        v_debit_account_id,
        v_credit_account_id,
        p_amount,
        p_user_data
    )
    returning id into v_transaction_id;

    return v_transaction_id;
end;
$$ language plpgsql security definer;


-- function to assign money from Income to a category (internal utility)
-- performs the core logic: finds accounts, validates, inserts transaction
-- returns a record matching the api.transactions view structure
create or replace function utils.assign_to_category(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text,
    p_user_data text = utils.get_user()
) returns table(
    -- results (fields returned by this function)
    r_uuid text,                  
    r_description text,           
    r_amount bigint,              
    r_date timestamptz,           
    r_metadata jsonb,             
    r_ledger_uuid text,           
    r_transaction_type text,      
    r_account_uuid text,          
    r_category_uuid text          
) as
$$
declare
    v_ledger_id int;
    v_income_account_id int;
    v_income_account_uuid text;
    v_category_account_id int;
    v_transaction_uuid text;
    v_metadata jsonb;
    v_transaction_record data.transactions;
begin
    -- validate input parameters early
    if p_amount <= 0 then 
        raise exception 'Assignment amount must be positive: %', p_amount; 
    end if;

    -- find ledger ID and validate ownership in a single query
    select l.id into v_ledger_id 
    from data.ledgers l 
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;
    
    if v_ledger_id is null then 
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid; 
    end if;

    -- find both Income account and target category in one efficient query
    -- using a CTE to avoid duplicate scans of the accounts table
    with account_data as (
        select a.id, a.uuid, a.name, a.type
        from data.accounts a
        where a.ledger_id = v_ledger_id 
          and a.user_data = p_user_data
          and ((a.name = 'Income' and a.type = 'equity') or a.uuid = p_category_uuid)
    )
    select 
        (select id from account_data where name = 'Income' and type = 'equity'),
        (select uuid from account_data where name = 'Income' and type = 'equity'),
        (select id from account_data where uuid = p_category_uuid)
    into v_income_account_id, v_income_account_uuid, v_category_account_id;

    -- validate accounts were found
    if v_income_account_id is null then 
        raise exception 'Income account not found for ledger % and user %', v_ledger_id, p_user_data; 
    end if;
    
    if v_category_account_id is null then 
        raise exception 'Category with UUID % not found or does not belong to ledger % for current user', 
                        p_category_uuid, v_ledger_id; 
    end if;

    -- create the transaction (debit Income, credit Category)
    -- and get the full record in one operation
    insert into data.transactions (
        ledger_id, 
        description, 
        date, 
        amount, 
        debit_account_id, 
        credit_account_id, 
        user_data
    ) values (
        v_ledger_id, 
        p_description, 
        p_date, 
        p_amount, 
        v_income_account_id, 
        v_category_account_id, 
        p_user_data
    ) returning * into v_transaction_record;

    -- return the full record matching the api.transactions view structure
    -- using a single VALUES expression is more efficient than a subquery
    return query
    values (
        v_transaction_record.uuid,  -- r_uuid
        p_description,              -- r_description
        p_amount,                   -- r_amount
        p_date,                     -- r_date
        v_transaction_record.metadata, -- r_metadata
        p_ledger_uuid,              -- r_ledger_uuid
        null::text,                 -- r_transaction_type (null for direct assignments)
        v_income_account_uuid,      -- r_account_uuid (using Income account)
        p_category_uuid             -- r_category_uuid
    );
end;
$$ language plpgsql volatile security definer;


-- Create a function to handle simple transaction insertion
create or replace function utils.simple_transactions_insert_fn() returns trigger as
$$
declare
    v_ledger_id             bigint;
    v_account_id            bigint;
    v_category_id           bigint;
    v_debit_account_id      bigint;
    v_credit_account_id     bigint;
    v_account_internal_type text;
    v_transaction_uuid      text;
    v_user_data             text := utils.get_user();
    v_category_uuid         text := NEW.category_uuid;
begin
    -- validate inputs early for fast failure
    if NEW.amount <= 0 then
        raise exception 'Transaction amount must be positive: %', NEW.amount;
    end if;

    if NEW.type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', NEW.type;
    end if;

    -- get the ledger_id and validate ownership in one query
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid
       and l.user_data = v_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', NEW.ledger_uuid;
    end if;

    -- find the account details in one query
    select a.id, a.internal_type
      into v_account_id, v_account_internal_type
      from data.accounts a
     where a.uuid = NEW.account_uuid
       and a.ledger_id = v_ledger_id
       and a.user_data = v_user_data;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger % for current user', 
                       NEW.account_uuid, NEW.ledger_uuid;
    end if;

    -- handle category lookup with a more efficient approach
    if v_category_uuid is null then
        -- Use a direct query to find the "Unassigned" category
        select a.id, a.uuid into v_category_id, v_category_uuid
          from data.accounts a
         where a.ledger_id = v_ledger_id
           and a.user_data = v_user_data
           and a.name = 'Unassigned'
           and a.type = 'equity';
           
        if v_category_id is null then
            raise exception 'Could not find "Unassigned" category in ledger % for current user', 
                           NEW.ledger_uuid;
        end if;
    else
        -- find the specified category
        select a.id into v_category_id
          from data.accounts a
         where a.uuid = v_category_uuid 
           and a.ledger_id = v_ledger_id
           and a.user_data = v_user_data;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger % for current user', 
                           v_category_uuid, NEW.ledger_uuid;
        end if;
    end if;

    -- determine debit and credit accounts based on account type and transaction type
    -- using a more readable CASE expression
    case 
        when v_account_internal_type = 'asset_like' and NEW.type = 'inflow' then
            -- inflow to asset: debit asset (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        when v_account_internal_type = 'asset_like' and NEW.type = 'outflow' then
            -- outflow from asset: debit category (decrease), credit asset (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and NEW.type = 'inflow' then
            -- inflow to liability: debit category (decrease), credit liability (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and NEW.type = 'outflow' then
            -- outflow from liability: debit liability (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        else
            raise exception 'Unsupported combination: account_type=% and transaction_type=%', 
                           v_account_internal_type, NEW.type;
    end case;

    -- insert the transaction into the transactions table with all necessary fields
    insert into data.transactions (
        description, 
        date, 
        amount, 
        debit_account_id, 
        credit_account_id, 
        ledger_id, 
        metadata,
        user_data
    )
    values (
        NEW.description,
        NEW.date,
        NEW.amount,
        v_debit_account_id,
        v_credit_account_id,
        v_ledger_id,
        NEW.metadata,
        v_user_data
    )
    returning uuid into v_transaction_uuid;

    -- Populate the NEW record with all necessary fields for the view
    NEW.uuid := v_transaction_uuid;
    -- The other fields are already set in NEW from the INSERT statement
    -- If category_uuid was null and we found Unassigned, update it
    if NEW.category_uuid is null then
        NEW.category_uuid := v_category_uuid;
    end if;

    return NEW;
end;
$$ language plpgsql security definer;


-- Create a function to handle simple transaction updates
create or replace function utils.simple_transactions_update_fn() returns trigger as
$$
declare
    v_ledger_id             bigint;
    v_account_id            bigint;
    v_category_id           bigint;
    v_debit_account_id      bigint;
    v_credit_account_id     bigint;
    v_account_internal_type text;
    v_transaction_id        bigint;
    v_user_data             text := utils.get_user();
    v_category_uuid         text := NEW.category_uuid;
    v_transaction_record    data.transactions;
begin
    -- Validate inputs early for fast failure
    if NEW.amount <= 0 then
        raise exception 'Transaction amount must be positive: %', NEW.amount;
    end if;

    if NEW.type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', NEW.type;
    end if;

    -- Get the transaction record and verify ownership in one query
    select t.* into v_transaction_record
      from data.transactions t
     where t.uuid = OLD.uuid
       and t.user_data = v_user_data;

    if v_transaction_record.id is null then
        raise exception 'Transaction with UUID % not found for current user', OLD.uuid;
    end if;
    
    v_transaction_id := v_transaction_record.id;

    -- Get the ledger_id and validate ownership
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = NEW.ledger_uuid
       and l.user_data = v_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', NEW.ledger_uuid;
    end if;

    -- Find the account details in one query
    select a.id, a.internal_type
      into v_account_id, v_account_internal_type
      from data.accounts a
     where a.uuid = NEW.account_uuid
       and a.ledger_id = v_ledger_id
       and a.user_data = v_user_data;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger % for current user', 
                       NEW.account_uuid, NEW.ledger_uuid;
    end if;

    -- Handle category lookup with a more efficient approach
    if v_category_uuid is null then
        -- Use a direct query to find the "Unassigned" category
        select a.id, a.uuid into v_category_id, v_category_uuid
          from data.accounts a
         where a.ledger_id = v_ledger_id
           and a.user_data = v_user_data
           and a.name = 'Unassigned'
           and a.type = 'equity';
           
        if v_category_id is null then
            raise exception 'Could not find "Unassigned" category in ledger % for current user', 
                           NEW.ledger_uuid;
        end if;
    else
        -- Find the specified category
        select a.id into v_category_id
          from data.accounts a
         where a.uuid = v_category_uuid 
           and a.ledger_id = v_ledger_id
           and a.user_data = v_user_data;

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger % for current user', 
                           v_category_uuid, NEW.ledger_uuid;
        end if;
    end if;

    -- Determine debit and credit accounts based on account type and transaction type
    -- Using a more readable CASE expression
    case 
        when v_account_internal_type = 'asset_like' and NEW.type = 'inflow' then
            -- Inflow to asset: debit asset (increase), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        when v_account_internal_type = 'asset_like' and NEW.type = 'outflow' then
            -- Outflow from asset: debit category (decrease), credit asset (decrease)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and NEW.type = 'inflow' then
            -- Inflow to liability: debit category (decrease), credit liability (increase)
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
            
        when v_account_internal_type = 'liability_like' and NEW.type = 'outflow' then
            -- Outflow from liability: debit liability (decrease), credit category (increase)
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
            
        else
            raise exception 'Unsupported combination: account_type=% and transaction_type=%', 
                           v_account_internal_type, NEW.type;
    end case;

    -- Update the transaction in data.transactions
    update data.transactions
       set description = NEW.description,
           date = NEW.date,
           amount = NEW.amount,
           debit_account_id = v_debit_account_id,
           credit_account_id = v_credit_account_id,
           ledger_id = v_ledger_id,
           metadata = NEW.metadata,
           updated_at = current_timestamp
     where id = v_transaction_id
     returning * into v_transaction_record;

    -- Populate the NEW record with values from the updated transaction
    NEW.uuid := v_transaction_record.uuid;
    -- If category_uuid was null and we found Unassigned, update it
    if NEW.category_uuid is null then
        NEW.category_uuid := v_category_uuid;
    end if;

    return NEW;
end;
$$ language plpgsql security definer;


-- Create a function to handle simple transaction deletions
create or replace function utils.simple_transactions_delete_fn() returns trigger as
$$
declare
    v_user_data text := utils.get_user();
    v_transaction_record data.transactions;
begin
    -- Get the transaction record and verify ownership in one query
    select * into v_transaction_record
    from data.transactions t
    where t.uuid = OLD.uuid
      and t.user_data = v_user_data;
    
    if v_transaction_record.id is null then
        raise exception 'Transaction with UUID % not found for current user', OLD.uuid;
    end if;
    
    -- Perform soft delete by setting deleted_at
    update data.transactions
    set deleted_at = current_timestamp
    where uuid = OLD.uuid and user_data = v_user_data
    returning * into v_transaction_record;
    
    -- Verify the update was successful
    if v_transaction_record.deleted_at is null then
        raise exception 'Failed to soft-delete transaction with UUID %', OLD.uuid;
    end if;
    
    return OLD;
end;
$$ language plpgsql volatile security definer;





-- From: 20250506165232_add_transactions_views.sql

-- This view is the primary interface for transactions.
-- It was formerly api.simple_transactions and is designed for simplified transaction entry.
-- The underlying double-entry logic is handled by INSTEAD OF triggers
-- calling utils.simple_transactions_*_fn functions.
create or replace view api.transactions with (security_invoker = true) as
select
    t.uuid,
    t.description,
    t.amount, -- This is the absolute amount of the transaction
    t.date,
    t.metadata,
    l.uuid as ledger_uuid,
    -- The following columns are primarily for the INSERT/UPDATE payload via the view.
    -- For SELECTs, their values might not be directly derivable from a single data.transactions row
    -- without knowing which account was the 'primary' one and which was the 'category' in the simplified model.
    -- The utils.simple_transactions_insert_fn populates these in the NEW record it returns.
    -- For direct SELECTs, these might need more complex logic or be NULL if not easily determined.
    -- For simplicity in SELECT, we'll make them NULL-able or derive if straightforward.
    -- The trigger functions are responsible for interpreting these from the NEW record on INSERT/UPDATE.
    null::text as type, -- Placeholder: The trigger function expects NEW.type ('inflow'/'outflow')
    null::text as account_uuid, -- Placeholder: The trigger function expects NEW.account_uuid
    null::text as category_uuid -- Placeholder: The trigger function expects NEW.category_uuid
from
    data.transactions t
    join data.ledgers l on t.ledger_id = l.id;
    -- Note: The actual values for account_uuid, category_uuid, and type for display (SELECT)
    -- would require reverse-engineering the logic from utils.simple_transactions_insert_fn
    -- or storing additional denormalized fields. For an updatable view, PostgREST primarily cares
    -- about the columns available in NEW for INSERT/UPDATE. The SELECT part of the view
    -- should ideally be consistent, but can be simpler if the primary use is mutation via triggers.
    -- The trigger functions will populate these fields in the returned NEW record.


-- function to assign money from Income to a category (public API)
-- This function provides a public interface for budget allocations
-- It simply passes through to the utils function which handles all the logic
create or replace function api.assign_to_category(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text
)
returns SETOF api.transactions as
$$
declare
    v_result record;
    
    -- Using %ROWTYPE ensures the returned row exactly matches the structure of the api.transactions view.
    -- This guarantees type compatibility and prevents structure mismatch errors when the function
    -- is called with a SELECT statement that expects specific columns in a specific order.
    v_transaction_row api.transactions%ROWTYPE;
begin
    -- Call the utils function and store the entire result in a record variable
    select * into v_result from utils.assign_to_category(
        p_ledger_uuid   := p_ledger_uuid,
        p_date          := p_date,
        p_description   := p_description,
        p_amount        := p_amount,
        p_category_uuid := p_category_uuid
    );
    
    -- Construct a single row of api.transactions type
    select 
        v_result.r_uuid::text,
        v_result.r_description::text,
        v_result.r_amount::bigint,
        v_result.r_date::timestamptz,
        v_result.r_metadata::jsonb,
        v_result.r_ledger_uuid::text,
        v_result.r_transaction_type::text,
        v_result.r_account_uuid::text,
        v_result.r_category_uuid::text
    into v_transaction_row;
    
    -- Return the single row
    return next v_transaction_row;
    return;
end;
$$ language plpgsql volatile security invoker;



-- From: 20250506165235_add_transactions_triggers.sql

-- Trigger for data.transactions table (internal audit timestamp)
create trigger transactions_updated_at_tg
    before update
    on data.transactions
    for each row
execute procedure utils.set_updated_at_fn();


-- Create or replace the simple_transactions_update_fn function
create or replace function utils.simple_transactions_update_fn()
returns trigger as $$
declare
    v_ledger_id bigint;
    v_account_id bigint;
    v_category_id bigint;
    v_user_data text := utils.get_user();
    v_transaction_record data.transactions;
begin
    -- Get the existing transaction record
    select * into v_transaction_record
    from data.transactions t
    where t.uuid = old.uuid and t.user_data = v_user_data;
    
    if v_transaction_record.id is null then
        raise exception 'Transaction with UUID % not found for current user', old.uuid;
    end if;
    
    -- Resolve ledger_uuid to internal ledger_id
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = new.ledger_uuid and l.user_data = v_user_data;
    
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', new.ledger_uuid;
    end if;
    
    -- Validate amount
    if new.amount <= 0 then
        raise exception 'Transaction amount must be positive: %', new.amount;
    end if;
    
    -- Validate transaction type
    if new.type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be either "inflow" or "outflow"', new.type;
    end if;
    
    -- Resolve account_uuid to internal account_id
    select a.id into v_account_id
    from data.accounts a
    where a.uuid = new.account_uuid and a.ledger_id = v_ledger_id and a.user_data = v_user_data;
    
    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger %', new.account_uuid, new.ledger_uuid;
    end if;
    
    -- Resolve category_uuid to internal category_id
    select a.id into v_category_id
    from data.accounts a
    where a.uuid = new.category_uuid and a.ledger_id = v_ledger_id and a.user_data = v_user_data;
    
    if v_category_id is null then
        raise exception 'Category with UUID % not found in ledger %', new.category_uuid, new.ledger_uuid;
    end if;
    
    -- Update the transaction based on type
    if new.type = 'inflow' then
        update data.transactions t
        set 
            description = new.description,
            date = new.date,
            amount = new.amount,
            metadata = new.metadata,
            ledger_id = v_ledger_id,
            debit_account_id = v_account_id,
            credit_account_id = v_category_id,
            updated_at = current_timestamp
        where t.uuid = old.uuid and t.user_data = v_user_data
        returning * into v_transaction_record;
    else -- outflow
        update data.transactions t
        set 
            description = new.description,
            date = new.date,
            amount = new.amount,
            metadata = new.metadata,
            ledger_id = v_ledger_id,
            debit_account_id = v_category_id,
            credit_account_id = v_account_id,
            updated_at = current_timestamp
        where t.uuid = old.uuid and t.user_data = v_user_data
        returning * into v_transaction_record;
    end if;
    
    -- Populate the NEW record with values from the updated transaction
    new.uuid := v_transaction_record.uuid;
    new.description := v_transaction_record.description;
    new.amount := v_transaction_record.amount;
    new.date := v_transaction_record.date;
    new.metadata := v_transaction_record.metadata;
    new.ledger_uuid := new.ledger_uuid; -- Already set
    new.account_uuid := new.account_uuid; -- Already set
    new.category_uuid := new.category_uuid; -- Already set
    new.type := new.type; -- Already set
    
    return new;
end;
$$ language plpgsql volatile security definer;

-- Create or replace the simple_transactions_delete_fn function
create or replace function utils.simple_transactions_delete_fn()
returns trigger as $$
declare
    v_user_data text := utils.get_user();
    v_transaction_record data.transactions;
begin
    -- Get the transaction record
    select * into v_transaction_record
    from data.transactions t
    where t.uuid = old.uuid and t.user_data = v_user_data;
    
    if v_transaction_record.id is null then
        raise exception 'Transaction with UUID % not found for current user', old.uuid;
    end if;
    
    -- Perform soft delete by setting deleted_at
    update data.transactions
    set deleted_at = current_timestamp
    where uuid = old.uuid and user_data = v_user_data;
    
    return old;
end;
$$ language plpgsql volatile security definer;

-- Triggers for the NEW api.transactions view (which was api.simple_transactions)
-- These are renamed from simple_transactions_*_tg and now target api.transactions
create trigger transactions_insert_tg -- RENAMED from simple_transactions_insert_tg
    instead of insert
    on api.transactions -- NOW targets the new api.transactions view
    for each row
execute function utils.simple_transactions_insert_fn(); -- Calls the simple util

create trigger transactions_update_tg -- RENAMED from simple_transactions_update_tg
    instead of update
    on api.transactions -- NOW targets the new api.transactions view
    for each row
execute function utils.simple_transactions_update_fn(); -- Calls the simple util

create trigger transactions_delete_tg -- RENAMED from simple_transactions_delete_tg
    instead of delete
    on api.transactions -- NOW targets the new api.transactions view
    for each row
execute function utils.simple_transactions_delete_fn(); -- Calls the simple util

-- Create or replace the api.transactions view to exclude soft-deleted transactions
-- create or replace view api.transactions with (security_invoker = true) as
-- select
--     t.uuid,
--     t.description,
--     t.amount,
--     t.date,
--     t.metadata,
--     l.uuid as ledger_uuid,
--     case
--         when t.debit_account_id = a_asset.id then 'inflow'
--         else 'outflow'
--     end as type,
--     case
--         when t.debit_account_id = a_asset.id then a_asset.uuid
--         else a_category.uuid
--     end as account_uuid,
--     case
--         when t.debit_account_id = a_asset.id then a_category.uuid
--         else a_asset.uuid
--     end as category_uuid
-- from
--     data.transactions t
-- join
--     data.ledgers l on t.ledger_id = l.id
-- join
--     data.accounts a_asset on (
--         (t.debit_account_id = a_asset.id and a_asset.type = 'asset') or
--         (t.credit_account_id = a_asset.id and a_asset.type = 'asset')
--     )
-- join
--     data.accounts a_category on (
--         (t.debit_account_id = a_category.id and a_category.type = 'equity') or
--         (t.credit_account_id = a_category.id and a_category.type = 'equity')
--     )
-- where
--     t.deleted_at is null; -- Exclude soft-deleted transactions



-- From: 20250506231409_add_balances_utils.sql

-- simple function to calculate account balance on-demand from transactions
create or replace function utils.get_account_balance(
    p_ledger_id bigint,
    p_account_id bigint
) returns bigint as $$
declare
    v_balance bigint := 0;
    v_internal_type text;
    v_account_ledger_id bigint;
begin
    -- get account type and verify it belongs to the specified ledger
    select internal_type, ledger_id 
    into v_internal_type, v_account_ledger_id
    from data.accounts 
    where id = p_account_id;
    
    if v_internal_type is null then
        raise exception 'Account with ID % not found', p_account_id;
    end if;
    
    if v_account_ledger_id != p_ledger_id then
        raise exception 'account not found or does not belong to the specified ledger';
    end if;
    
    -- calculate balance by summing all non-deleted transactions
    -- using ledger_id in WHERE clause for better performance
    if v_internal_type = 'asset_like' then
        select coalesce(sum(
            case 
                when debit_account_id = p_account_id then amount
                when credit_account_id = p_account_id then -amount
                else 0
            end
        ), 0) into v_balance
        from data.transactions
        where ledger_id = p_ledger_id
          and (debit_account_id = p_account_id or credit_account_id = p_account_id)
          and deleted_at is null;
    else -- liability_like
        select coalesce(sum(
            case 
                when credit_account_id = p_account_id then amount
                when debit_account_id = p_account_id then -amount
                else 0
            end
        ), 0) into v_balance
        from data.transactions
        where ledger_id = p_ledger_id
          and (debit_account_id = p_account_id or credit_account_id = p_account_id)
          and deleted_at is null;
    end if;
    
    return v_balance;
end;
$$ language plpgsql stable security definer;


-- simple function to get account transactions with running balances
create or replace function utils.get_account_transactions(
    p_account_uuid text,
    p_user_data text default utils.get_user()
)
returns table (
    date date,
    category text,
    description text,
    type text,
    amount bigint,
    running_balance bigint
) as $$
declare
    v_account_id bigint;
    v_internal_type text;
begin
    -- resolve the account uuid to its internal id and validate ownership
    select a.id, a.internal_type 
    into v_account_id, v_internal_type
    from data.accounts a
    where a.uuid = p_account_uuid and a.user_data = p_user_data;
    
    -- check if account exists and belongs to the user
    if v_account_id is null then
        raise exception 'Account with UUID % not found for current user', p_account_uuid;
    end if;

    -- return account transactions with running balances from balance snapshots
    -- this uses the balance_snapshots table which stores the balance after each transaction
    return query
    select
        t.date,
        -- get the other account's name as category
        case 
            when t.debit_account_id = v_account_id then 
                (select name from data.accounts where id = t.credit_account_id)
            else 
                (select name from data.accounts where id = t.debit_account_id)
        end as category,
        t.description,
        -- determine transaction type based on account's internal type
        case 
            when (v_internal_type = 'asset_like' and t.debit_account_id = v_account_id) or
                 (v_internal_type = 'liability_like' and t.credit_account_id = v_account_id)
            then 'inflow'
            else 'outflow'
        end as type,
        t.amount,
        -- get the running balance from the balance snapshot for this transaction
        coalesce(bs.balance, 0) as running_balance
    from 
        data.transactions t
        left join data.balance_snapshots bs on (
            bs.transaction_id = t.id 
            and bs.account_id = v_account_id
            and bs.user_data = p_user_data
        )
    where 
        (t.debit_account_id = v_account_id or t.credit_account_id = v_account_id)
        and t.deleted_at is null
    order by 
        t.date desc, 
        t.created_at desc;
end;
$$ language plpgsql stable security definer;

-- simple function to get budget status using on-demand balance calculations
create or replace function utils.get_budget_status(
    p_ledger_uuid text,
    p_user_data text default utils.get_user()
)
returns table (
    account_uuid text,
    account_name text,
    budgeted     decimal,
    activity     decimal,
    balance      decimal
) as $$
declare
    v_ledger_id bigint;
begin
    -- find the ledger id and validate ownership
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;
    
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;
    
    -- return budget status for all categories in the ledger
    return query
    with categories as (
        -- get all budget categories (equity accounts except special ones)
        select 
            a.id, 
            a.uuid, 
            a.name
        from 
            data.accounts a
        where 
            a.ledger_id = v_ledger_id
            and a.user_data = p_user_data
            and a.type = 'equity'
            and a.name not in ('Income', 'Off-budget', 'Unassigned')
    ),
    income_account as (
        -- get the income account id for this ledger
        select a.id
        from data.accounts a
        where a.ledger_id = v_ledger_id
          and a.user_data = p_user_data
          and a.type = 'equity'
          and a.name = 'Income'
        limit 1
    ),
    budget_transactions as (
        -- transactions from income to categories (budget allocations)
        select 
            t.credit_account_id as category_id,
            sum(t.amount) as amount
        from 
            data.transactions t
        where 
            t.ledger_id = v_ledger_id
            and t.user_data = p_user_data
            and t.debit_account_id = (select id from income_account)
            and t.deleted_at is null
        group by 
            t.credit_account_id
    ),
    activity_transactions as (
        -- transactions between categories and asset/liability accounts
        select 
            case 
                when t.debit_account_id in (select id from categories) then t.debit_account_id
                else t.credit_account_id
            end as category_id,
            sum(
                case 
                    when t.debit_account_id in (select id from categories) then -t.amount
                    else t.amount
                end
            ) as amount
        from 
            data.transactions t
        where 
            t.ledger_id = v_ledger_id
            and t.user_data = p_user_data
            and (
                (t.debit_account_id in (select id from categories) and 
                 t.credit_account_id in (select id from data.accounts where ledger_id = v_ledger_id and type in ('asset', 'liability'))) or
                (t.credit_account_id in (select id from categories) and 
                 t.debit_account_id in (select id from data.accounts where ledger_id = v_ledger_id and type in ('asset', 'liability')))
            )
            and t.deleted_at is null
        group by 
            case 
                when t.debit_account_id in (select id from categories) then t.debit_account_id
                else t.credit_account_id
            end
    )
    
    -- final result combining all the data
    select 
        c.uuid as account_uuid,
        c.name as account_name,
        coalesce(b.amount, 0)::decimal as budgeted,
        coalesce(a.amount, 0)::decimal as activity,
        utils.get_account_balance(v_ledger_id, c.id)::decimal as balance
    from 
        categories c
    left join 
        budget_transactions b on c.id = b.category_id
    left join 
        activity_transactions a on c.id = a.category_id
    order by 
        c.name;
end;
$$ language plpgsql stable security definer;




-- From: 20250506231415_add_balances_views.sql

-- simplified api function to expose budget status
create or replace function api.get_budget_status(
    p_ledger_uuid text
) returns table (
    category_uuid text,
    category_name text,
    budgeted bigint,
    activity bigint,
    balance bigint
) as $$
begin
    -- simply call the utils function and transform the results for the api
    return query
    select 
        bs.account_uuid as category_uuid,
        bs.account_name as category_name,
        bs.budgeted::bigint,
        bs.activity::bigint,
        bs.balance::bigint
    from utils.get_budget_status(p_ledger_uuid) bs;
end;
$$ language plpgsql stable security invoker;

-- simplified api function that passes through to the utils function
create or replace function api.get_account_transactions(
    p_account_uuid text
) returns table (
    date date,
    category text,
    description text,
    type text,
    amount bigint,
    running_balance bigint
) as $$
begin
    -- simply call the utils function and return the results
    return query
    select * from utils.get_account_transactions(p_account_uuid);
end;
$$ language plpgsql stable security invoker;



-- From: 20250822162330_add_transaction_log.sql

-- track all transaction corrections and deletions for audit trail
create table data.transaction_log
(
    id bigint generated always as identity,
    original_transaction_id bigint not null,
    reversal_transaction_id bigint,
    correction_transaction_id bigint,
    mutation_type text not null,
    reason text,
    created_at timestamptz not null default current_timestamp,
    user_data text not null default utils.get_user(),

    constraint transaction_log_id_pk primary key (id),
    constraint transaction_log_original_transaction_id_fk foreign key (original_transaction_id) references data.transactions(id),
    constraint transaction_log_reversal_transaction_id_fk foreign key (reversal_transaction_id) references data.transactions(id),
    constraint transaction_log_correction_transaction_id_fk foreign key (correction_transaction_id) references data.transactions(id),
    constraint transaction_log_mutation_type_check check (mutation_type in ('correction', 'deletion'))
);

-- index for querying transaction history by original transaction
create index idx_transaction_log_original_id on data.transaction_log(original_transaction_id);



-- From: 20250822165949_add_correction_functions.sql

-- utils function to correct a transaction (internal business logic)
create or replace function utils.correct_transaction(
    p_original_uuid text,
    p_new_type text,
    p_new_account_uuid text,
    p_new_category_uuid text,
    p_new_amount bigint,
    p_new_description text,
    p_new_date date,
    p_reason text default 'Transaction correction'
) returns int as $$
declare
    v_original_tx data.transactions;
    v_ledger_uuid text;
    v_account_id bigint;
    v_category_id bigint;
    v_reversal_id bigint;
    v_correction_id bigint;
    v_debit_account_id bigint;
    v_credit_account_id bigint;
begin
    -- get original transaction
    select t.* into v_original_tx
    from data.transactions t
    where t.uuid = p_original_uuid 
      and t.user_data = utils.get_user();
    
    if v_original_tx.id is null then
        raise exception 'Transaction not found: %', p_original_uuid;
    end if;
    
    -- get ledger uuid
    select l.uuid into v_ledger_uuid
    from data.ledgers l
    where l.id = v_original_tx.ledger_id;
    
    -- resolve account id from uuid
    select id into v_account_id 
    from data.accounts 
    where uuid = p_new_account_uuid and user_data = utils.get_user();
    
    if v_account_id is null then
        raise exception 'Account not found: %', p_new_account_uuid;
    end if;
    
    -- handle category lookup (default to Unassigned if null)
    if p_new_category_uuid is null then
        -- use utils.find_category to get "Unassigned" category UUID
        declare
            v_unassigned_uuid text;
        begin
            select utils.find_category(v_ledger_uuid, 'Unassigned') into v_unassigned_uuid;
            
            if v_unassigned_uuid is null then
                raise exception 'Could not find "Unassigned" category in ledger for current user';
            end if;
            
            -- convert UUID to ID
            select id into v_category_id 
            from data.accounts 
            where uuid = v_unassigned_uuid and user_data = utils.get_user();
        end;
    else
        -- find the specified category
        select id into v_category_id 
        from data.accounts 
        where uuid = p_new_category_uuid and user_data = utils.get_user();
        
        if v_category_id is null then
            raise exception 'Category not found: %', p_new_category_uuid;
        end if;
    end if;
    
    -- determine debit/credit based on transaction type (budgeting logic)
    case p_new_type
        when 'outflow' then
            -- money leaves account, goes to category
            v_debit_account_id := v_category_id;
            v_credit_account_id := v_account_id;
        when 'inflow' then
            -- money enters account, comes from category  
            v_debit_account_id := v_account_id;
            v_credit_account_id := v_category_id;
        else
            raise exception 'Invalid transaction type: %. Must be "inflow" or "outflow"', p_new_type;
    end case;
    
    -- create reversal transaction (opposite of original)
    insert into data.transactions (amount, description, date, debit_account_id, credit_account_id, ledger_id, user_data)
    values (
        v_original_tx.amount,
        'REVERSAL: ' || v_original_tx.description,
        v_original_tx.date,
        v_original_tx.credit_account_id,  -- swap accounts to reverse
        v_original_tx.debit_account_id,
        v_original_tx.ledger_id,
        utils.get_user()
    ) returning id into v_reversal_id;
    
    -- create corrected transaction with new values
    insert into data.transactions (amount, description, date, debit_account_id, credit_account_id, ledger_id, user_data)
    values (
        p_new_amount,
        p_new_description,
        p_new_date,
        v_debit_account_id,
        v_credit_account_id,
        v_original_tx.ledger_id,
        utils.get_user()
    ) returning id into v_correction_id;
    
    -- record the correction in transaction log
    insert into data.transaction_log (original_transaction_id, reversal_transaction_id, correction_transaction_id, mutation_type, reason)
    values (
        v_original_tx.id,
        v_reversal_id,
        v_correction_id,
        'correction',
        p_reason
    );
    
    return v_correction_id;
end;
$$ language plpgsql security definer;

-- utils function to delete a transaction (internal business logic)
create or replace function utils.delete_transaction(
    p_original_uuid text,
    p_reason text default 'Transaction deleted'
) returns int as $$
declare
    v_original_tx data.transactions;
    v_reversal_id bigint;
begin
    -- get original transaction
    select * into v_original_tx 
    from data.transactions 
    where uuid = p_original_uuid 
      and user_data = utils.get_user();
    
    if v_original_tx.id is null then
        raise exception 'Transaction not found: %', p_original_uuid;
    end if;
    
    -- create reversal transaction to cancel original
    insert into data.transactions (amount, description, date, debit_account_id, credit_account_id, ledger_id, user_data)
    values (
        v_original_tx.amount,
        'DELETED: ' || v_original_tx.description,
        v_original_tx.date,
        v_original_tx.credit_account_id,  -- swap accounts to reverse
        v_original_tx.debit_account_id,
        v_original_tx.ledger_id,
        utils.get_user()
    ) returning id into v_reversal_id;
    
    -- record the deletion in transaction log
    insert into data.transaction_log (original_transaction_id, reversal_transaction_id, mutation_type, reason)
    values (
        v_original_tx.id,
        v_reversal_id,
        'deletion',
        p_reason
    );
    
    return v_reversal_id;
end;
$$ language plpgsql security definer;

-- api function to correct a transaction (thin public wrapper)
create or replace function api.correct_transaction(
    p_original_uuid text,
    p_new_type text,
    p_new_account_uuid text,
    p_new_category_uuid text,
    p_new_amount bigint,
    p_new_description text,
    p_new_date date,
    p_reason text default 'Transaction correction'
) returns text as $$
declare
    v_correction_id int;
    v_correction_uuid text;
begin
    -- call utils function to do all the work
    select utils.correct_transaction(
        p_original_uuid,
        p_new_type,
        p_new_account_uuid,
        p_new_category_uuid,
        p_new_amount,
        p_new_description,
        p_new_date,
        p_reason
    ) into v_correction_id;
    
    -- get the uuid of the corrected transaction
    select uuid into v_correction_uuid
    from data.transactions
    where id = v_correction_id;
    
    return v_correction_uuid;
end;
$$ language plpgsql security definer;

-- api function to delete a transaction (thin public wrapper)
create or replace function api.delete_transaction(
    p_original_uuid text,
    p_reason text default 'Transaction deleted'
) returns text as $$
declare
    v_reversal_id int;
    v_reversal_uuid text;
begin
    -- call utils function to do all the work
    select utils.delete_transaction(
        p_original_uuid,
        p_reason
    ) into v_reversal_id;
    
    -- get the uuid of the reversal transaction
    select uuid into v_reversal_uuid
    from data.transactions
    where id = v_reversal_id;
    
    return v_reversal_uuid;
end;
$$ language plpgsql security definer;



-- From: 20250822170217_remove_update_delete_triggers.sql

-- remove only update/delete triggers to make transactions immutable
-- keep insert trigger so users can still create transactions via the simplified api
drop trigger if exists transactions_update_tg on api.transactions;
drop trigger if exists transactions_delete_tg on api.transactions;

-- drop the update/delete trigger functions
drop function if exists utils.simple_transactions_update_fn();
drop function if exists utils.simple_transactions_delete_fn();

-- add comment explaining the change
comment on view api.transactions is 'Transactions are immutable after creation. Use api.correct_transaction() or api.delete_transaction() to modify existing transactions.';



-- From: 20250822172447_add_api_add_transaction.sql

-- public api function to add a transaction (calls utils function)
-- this provides a stable public interface while allowing internal changes
create or replace function api.add_transaction(
    p_ledger_uuid text,
    p_date date,
    p_description text,
    p_type text, -- 'inflow' or 'outflow'
    p_amount bigint,
    p_account_uuid text, -- the bank account or credit card
    p_category_uuid text default null -- the category, optional
) returns text as $$
declare
    v_transaction_id int;
    v_transaction_uuid text;
begin
    -- validate transaction type
    if p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: %. Must be "inflow" or "outflow"', p_type;
    end if;
    
    -- call the utils function
    select utils.add_transaction(
        p_ledger_uuid,
        p_date::timestamptz,
        p_description,
        p_type,
        p_amount,
        p_account_uuid,
        p_category_uuid
    ) into v_transaction_id;
    
    -- get the uuid of the created transaction
    select uuid into v_transaction_uuid
    from data.transactions
    where id = v_transaction_id;
    
    return v_transaction_uuid;
end;
$$ language plpgsql security definer;



-- From: 20250822175539_add_balances_table.sql

-- create balance snapshots table - one record per transaction per affected account
create table data.balance_snapshots
(
    id bigint generated always as identity,
    account_id bigint not null,
    transaction_id bigint not null,
    balance bigint not null,
    created_at timestamptz not null default current_timestamp,
    user_data text not null default utils.get_user(),

    constraint balance_snapshots_id_pk primary key (id),
    constraint balance_snapshots_account_id_fk foreign key (account_id) references data.accounts(id),
    constraint balance_snapshots_transaction_id_fk foreign key (transaction_id) references data.transactions(id),
    constraint balance_snapshots_account_transaction_unique unique (account_id, transaction_id, user_data)
);

-- index for fast current balance lookups (latest transaction per account)
create index idx_balance_snapshots_account_transaction on data.balance_snapshots(account_id, transaction_id desc);

-- index for user data isolation
create index idx_balance_snapshots_user_data on data.balance_snapshots(user_data);

-- index for transaction-based queries
create index idx_balance_snapshots_transaction_id on data.balance_snapshots(transaction_id);

-- function to get current balance for an account (latest snapshot)
create or replace function utils.get_account_current_balance(
    p_account_id bigint
) returns bigint as $$
declare
    v_balance bigint;
begin
    -- get the most recent balance snapshot for this account
    select balance into v_balance
    from data.balance_snapshots
    where account_id = p_account_id 
      and user_data = utils.get_user()
    order by transaction_id desc
    limit 1;
    
    return coalesce(v_balance, 0);
end;
$$ language plpgsql security definer;

-- function to create balance snapshots for a transaction
create or replace function utils.create_balance_snapshots(
    p_transaction_id bigint
) returns void as $$
declare
    v_transaction data.transactions;
    v_debit_account data.accounts;
    v_credit_account data.accounts;
    v_debit_balance bigint;
    v_credit_balance bigint;
begin
    -- get transaction details
    select * into v_transaction
    from data.transactions
    where id = p_transaction_id and user_data = utils.get_user();
    
    if v_transaction.id is null then
        return; -- transaction not found or not owned by user
    end if;
    
    -- get account details for proper balance calculation
    select * into v_debit_account
    from data.accounts
    where id = v_transaction.debit_account_id and user_data = utils.get_user();
    
    select * into v_credit_account
    from data.accounts
    where id = v_transaction.credit_account_id and user_data = utils.get_user();
    
    -- calculate new balances based on account types and double-entry rules
    -- for debit account: assets increase with debits, equity/liability decrease with debits
    if v_debit_account.internal_type = 'asset_like' then
        v_debit_balance := utils.get_account_current_balance(v_transaction.debit_account_id) + v_transaction.amount;
    else -- equity_like or liability_like
        v_debit_balance := utils.get_account_current_balance(v_transaction.debit_account_id) - v_transaction.amount;
    end if;
    
    -- for credit account: assets decrease with credits, equity/liability increase with credits
    if v_credit_account.internal_type = 'asset_like' then
        v_credit_balance := utils.get_account_current_balance(v_transaction.credit_account_id) - v_transaction.amount;
    else -- equity_like or liability_like
        v_credit_balance := utils.get_account_current_balance(v_transaction.credit_account_id) + v_transaction.amount;
    end if;
    
    -- create balance snapshot for debit account
    insert into data.balance_snapshots (account_id, transaction_id, balance, user_data)
    values (v_transaction.debit_account_id, p_transaction_id, v_debit_balance, utils.get_user())
    on conflict (account_id, transaction_id, user_data) do nothing;
    
    -- create balance snapshot for credit account
    insert into data.balance_snapshots (account_id, transaction_id, balance, user_data)
    values (v_transaction.credit_account_id, p_transaction_id, v_credit_balance, utils.get_user())
    on conflict (account_id, transaction_id, user_data) do nothing;
end;
$$ language plpgsql security definer;

-- function to rebuild all balance snapshots for an account (for data repair)
create or replace function utils.rebuild_account_balance_snapshots(
    p_account_id bigint
) returns void as $$
declare
    v_transaction record;
    v_account data.accounts;
    v_running_balance bigint := 0;
begin
    -- get account details for proper balance calculation
    select * into v_account
    from data.accounts
    where id = p_account_id and user_data = utils.get_user();
    
    if v_account.id is null then
        return; -- account not found or not owned by user
    end if;
    
    -- delete existing snapshots for this account
    delete from data.balance_snapshots
    where account_id = p_account_id and user_data = utils.get_user();
    
    -- rebuild snapshots by processing transactions in chronological order
    for v_transaction in
        select id, amount,
               case 
                   when debit_account_id = p_account_id then
                       case when v_account.internal_type = 'asset_like' then amount
                            else -amount end
                   when credit_account_id = p_account_id then
                       case when v_account.internal_type = 'asset_like' then -amount
                            else amount end
                   else 0 
               end as balance_change
        from data.transactions
        where (debit_account_id = p_account_id or credit_account_id = p_account_id)
          and user_data = utils.get_user()
        order by id
    loop
        v_running_balance := v_running_balance + v_transaction.balance_change;
        
        insert into data.balance_snapshots (account_id, transaction_id, balance, user_data)
        values (p_account_id, v_transaction.id, v_running_balance, utils.get_user());
    end loop;
end;
$$ language plpgsql security definer;



-- From: 20250822175708_add_balance_triggers.sql

-- trigger function to create balance snapshots when transactions are inserted
create or replace function utils.transaction_balance_snapshot_fn() returns trigger as $$
begin
    -- create balance snapshots for the new transaction
    perform utils.create_balance_snapshots(new.id);
    return new;
end;
$$ language plpgsql security definer;

-- trigger to automatically create balance snapshots when transactions are added
create trigger transaction_balance_snapshot_tg
    after insert on data.transactions
    for each row
    execute function utils.transaction_balance_snapshot_fn();



-- From: 20250822180245_add_balance_api_functions.sql

-- utils function to get account balance from snapshots (internal)
create or replace function utils.get_account_balance_from_snapshots(
    p_account_uuid text
) returns bigint as $$
declare
    v_account_id bigint;
begin
    -- get account id
    select id into v_account_id
    from data.accounts
    where uuid = p_account_uuid and user_data = utils.get_user();
    
    if v_account_id is null then
        raise exception 'account not found or does not belong to the specified ledger: %', p_account_uuid;
    end if;
    
    return utils.get_account_current_balance(v_account_id);
end;
$$ language plpgsql security definer;

-- api function to get account balance (public interface)
create or replace function api.get_account_balance(
    p_account_uuid text
) returns bigint as $$
begin
    return utils.get_account_balance_from_snapshots(p_account_uuid);
end;
$$ language plpgsql security definer;

-- utils function to get balance history for an account (internal)
create or replace function utils.get_account_balance_history(
    p_account_uuid text,
    p_limit int default 100
) returns table(
    transaction_id bigint,
    balance bigint,
    created_at timestamptz
) as $$
declare
    v_account_id bigint;
begin
    -- get account id
    select id into v_account_id
    from data.accounts
    where uuid = p_account_uuid and user_data = utils.get_user();
    
    if v_account_id is null then
        raise exception 'Account not found: %', p_account_uuid;
    end if;
    
    -- return balance history for the account
    return query
    select 
        bs.transaction_id,
        bs.balance,
        bs.created_at
    from data.balance_snapshots bs
    where bs.account_id = v_account_id 
      and bs.user_data = utils.get_user()
    order by bs.transaction_id desc
    limit p_limit;
end;
$$ language plpgsql security definer;

-- api function to get balance history for an account (public interface)
create or replace function api.get_account_balance_history(
    p_account_uuid text,
    p_limit int default 100
) returns table(
    transaction_id bigint,
    balance bigint,
    created_at timestamptz
) as $$
begin
    return query
    select * from utils.get_account_balance_history(p_account_uuid, p_limit);
end;
$$ language plpgsql security definer;

-- utils function to get all current balances for a ledger (internal)
create or replace function utils.get_ledger_current_balances(
    p_ledger_uuid text
) returns table(
    account_uuid text,
    account_name text,
    account_type text,
    current_balance bigint
) as $$
declare
    v_ledger_id bigint;
begin
    -- get ledger id
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();
    
    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;
    
    -- return current balance for each account in the ledger
    return query
    select 
        a.uuid::text,
        a.name,
        a.type,
        coalesce(utils.get_account_current_balance(a.id), 0)
    from data.accounts a
    where a.ledger_id = v_ledger_id 
      and a.user_data = utils.get_user()
    order by a.type, a.name;
end;
$$ language plpgsql security definer;

-- api function to get all current balances for a ledger (public interface)
create or replace function api.get_ledger_balances(
    p_ledger_uuid text
) returns table(
    account_uuid text,
    account_name text,
    account_type text,
    current_balance bigint
) as $$
begin
    return query
    select 
        u.account_uuid,
        u.account_name,
        u.account_type,
        u.current_balance
    from utils.get_ledger_current_balances(p_ledger_uuid) u;
end;
$$ language plpgsql security definer;

-- utils function to rebuild balance snapshots for a ledger (internal)
create or replace function utils.rebuild_ledger_balance_snapshots(
    p_ledger_uuid text
) returns void as $$
declare
    v_ledger_id bigint;
    v_account record;
begin
    -- get ledger id
    select id into v_ledger_id
    from data.ledgers
    where uuid = p_ledger_uuid and user_data = utils.get_user();
    
    if v_ledger_id is null then
        raise exception 'Ledger not found: %', p_ledger_uuid;
    end if;
    
    -- rebuild snapshots for each account in the ledger
    for v_account in
        select id from data.accounts
        where ledger_id = v_ledger_id and user_data = utils.get_user()
    loop
        perform utils.rebuild_account_balance_snapshots(v_account.id);
    end loop;
end;
$$ language plpgsql security definer;

-- api function to rebuild balance snapshots for a ledger (public interface)
create or replace function api.rebuild_ledger_balance_snapshots(
    p_ledger_uuid text
) returns void as $$
begin
    perform utils.rebuild_ledger_balance_snapshots(p_ledger_uuid);
end;
$$ language plpgsql security definer;



-- From: 20250823234210_enhanced_error_handling.sql

-- enhanced error handling utilities and improvements
-- following postgresql conventions with lowercase sql and comments above each step

-- create error handling utility functions in utils schema
-- standardize constraint violation messages with user-friendly text
create or replace function utils.handle_constraint_violation(
    p_constraint_name text,
    p_table_name text,
    p_column_value text default null
) returns text as $$
begin
    -- handle unique constraint violations with user-friendly messages
    case p_constraint_name
        when 'ledgers_name_user_unique' then
            return format('A ledger named "%s" already exists. Please choose a different name.', p_column_value);
        when 'accounts_name_ledger_unique' then
            return format('An account named "%s" already exists in this ledger. Please choose a different name.', p_column_value);
        when 'ledgers_uuid_unique' then
            return 'Ledger UUID conflict detected. Please try again.';
        when 'accounts_uuid_unique' then
            return 'Account UUID conflict detected. Please try again.';
        when 'transactions_uuid_unique' then
            return 'Transaction UUID conflict detected. Please try again.';
        when 'balance_snapshots_account_transaction_unique' then
            return 'Balance snapshot already exists for this transaction.';
        else
            -- fallback for unknown constraints
            return format('Duplicate entry detected for %s. Please check your input and try again.', coalesce(p_table_name, 'record'));
    end case;
end;
$$ language plpgsql immutable;

-- create transaction validation utility function
-- validate transaction amounts, dates, and business rules
create or replace function utils.validate_transaction_data(
    p_amount bigint,
    p_date timestamptz,
    p_type text default null
) returns void as $$
begin
    -- validate amount is positive
    if p_amount <= 0 then
        raise exception 'Transaction amount must be positive. Received: $%.%', 
            p_amount / 100, lpad((p_amount % 100)::text, 2, '0');
    end if;
    
    -- validate amount is reasonable (less than $1 million)
    if p_amount > 100000000 then -- $1,000,000.00 in cents
        raise exception 'Transaction amount exceeds maximum limit of $1,000,000.00. Received: $%.%',
            p_amount / 100, lpad((p_amount % 100)::text, 2, '0');
    end if;
    
    -- validate date is not too far in the future (more than 1 year)
    if p_date > current_timestamp + interval '1 year' then
        raise exception 'Transaction date cannot be more than 1 year in the future. Received: %', 
            p_date::date;
    end if;
    
    -- validate date is not too far in the past (more than 10 years)
    if p_date < current_timestamp - interval '10 years' then
        raise exception 'Transaction date cannot be more than 10 years in the past. Received: %', 
            p_date::date;
    end if;
    
    -- validate transaction type if provided
    if p_type is not null and p_type not in ('inflow', 'outflow') then
        raise exception 'Invalid transaction type: "%". Must be either "inflow" or "outflow".', p_type;
    end if;
end;
$$ language plpgsql immutable;

-- create input validation utility function
-- validate common input parameters like names, descriptions
create or replace function utils.validate_input_data(
    p_name text default null,
    p_description text default null,
    p_field_name text default 'field'
) returns text as $$
declare
    v_cleaned_name text;
begin
    -- validate and clean name if provided
    if p_name is not null then
        -- trim whitespace
        v_cleaned_name := trim(p_name);
        
        -- check if empty after trimming
        if v_cleaned_name = '' then
            raise exception '% name cannot be empty or contain only whitespace.', initcap(p_field_name);
        end if;
        
        -- check length constraints
        if char_length(v_cleaned_name) > 255 then
            raise exception '% name cannot exceed 255 characters. Current length: %', 
                initcap(p_field_name), char_length(v_cleaned_name);
        end if;
        
        -- check for invalid characters (basic validation)
        if v_cleaned_name ~ '[<>"\\/]' then
            raise exception '% name contains invalid characters. Please avoid: < > " \ /', 
                initcap(p_field_name);
        end if;
        
        return v_cleaned_name;
    end if;
    
    -- validate description length if provided
    if p_description is not null and char_length(p_description) > 1000 then
        raise exception 'Description cannot exceed 1000 characters. Current length: %', 
            char_length(p_description);
    end if;
    
    return p_name;
end;
$$ language plpgsql immutable;



-- From: 20250823234622_enhance_existing_functions.sql

-- enhance existing functions with improved error handling
-- following postgresql conventions with lowercase sql and comments above each step

-- enhance utils.add_category function with better error handling
create or replace function utils.add_category(
    p_ledger_uuid text,
    p_name text,
    p_user_data text = utils.get_user()
) returns data.accounts as
$$
declare
    v_ledger_id int;
    v_account_record data.accounts;
    v_cleaned_name text;
begin
    -- validate and clean input data using new utility function
    v_cleaned_name := utils.validate_input_data(p_name, null, 'category');
    
    -- find the ledger ID for the specified UUID and user
    select l.id
      into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    -- raise exception if ledger not found for the user
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- create the category account (equity type, liability_like behavior)
    -- associate it with the user using user_data
    begin
        insert into data.accounts (ledger_id, name, type, internal_type, user_data)
        values (v_ledger_id, v_cleaned_name, 'equity', 'liability_like', p_user_data)
        returning * into v_account_record;
    exception
        when unique_violation then
            -- use new error handling utility for user-friendly message
            raise exception using 
                message = utils.handle_constraint_violation('accounts_name_ledger_unique', 'accounts', v_cleaned_name),
                errcode = 'unique_violation';
        when foreign_key_violation then
            raise exception 'Invalid ledger reference. Please verify the ledger exists.';
    end;

    return v_account_record;
end;
$$ language plpgsql security definer;

-- enhance utils.add_transaction function with better validation and error handling
create or replace function utils.add_transaction(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_type text,
    p_amount bigint,
    p_account_uuid text,
    p_category_uuid text = null,
    p_user_data text = utils.get_user()
) returns int as
$$
declare
    v_ledger_id             int;
    v_account_id            int;
    v_account_internal_type text;
    v_category_id           int;
    v_transaction_id        int;
    v_debit_account_id      int;
    v_credit_account_id     int;
    v_cleaned_description   text;
begin
    -- validate transaction data using new utility function
    perform utils.validate_transaction_data(p_amount, p_date, p_type);
    
    -- validate and clean description
    v_cleaned_description := coalesce(trim(p_description), '');
    if char_length(v_cleaned_description) > 500 then
        raise exception 'Transaction description cannot exceed 500 characters. Current length: %', 
            char_length(v_cleaned_description);
    end if;

    -- find the ledger_id from uuid and validate ownership
    select l.id into v_ledger_id
      from data.ledgers l
     where l.uuid = p_ledger_uuid
       and l.user_data = p_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- find the account_id and internal_type in one query
    select a.id, a.internal_type 
      into v_account_id, v_account_internal_type
      from data.accounts a
     where a.uuid = p_account_uuid 
       and a.ledger_id = v_ledger_id
       and a.user_data = p_user_data;

    if v_account_id is null then
        raise exception 'Account with UUID % not found in ledger % for current user', 
                       p_account_uuid, p_ledger_uuid;
    end if;

    -- handle category lookup with enhanced error handling
    if p_category_uuid is null then
        -- find the "Unassigned" category directly
        select a.id into v_category_id
          from data.accounts a
         where a.ledger_id = v_ledger_id
           and a.user_data = p_user_data
           and a.name = 'Unassigned'
           and a.type = 'equity';
           
        if v_category_id is null then
            raise exception 'Default "Unassigned" category not found in ledger %. This indicates a system error.', 
                p_ledger_uuid;
        end if;
    else
        -- find the category by UUID
        select a.id into v_category_id
          from data.accounts a
         where a.uuid = p_category_uuid
           and a.ledger_id = v_ledger_id
           and a.user_data = p_user_data
           and a.type = 'equity';

        if v_category_id is null then
            raise exception 'Category with UUID % not found in ledger % for current user', 
                           p_category_uuid, p_ledger_uuid;
        end if;
    end if;

    -- validate account type and transaction type combination
    if (v_account_internal_type = 'asset_like' and p_type = 'outflow') or
       (v_account_internal_type = 'liability_like' and p_type = 'inflow') then
        -- debit category, credit account
        v_debit_account_id := v_category_id;
        v_credit_account_id := v_account_id;
    elsif (v_account_internal_type = 'asset_like' and p_type = 'inflow') or
          (v_account_internal_type = 'liability_like' and p_type = 'outflow') then
        -- debit account, credit category
        v_debit_account_id := v_account_id;
        v_credit_account_id := v_category_id;
    else
        raise exception 'Invalid combination: account type "%" with transaction type "%". Please verify your account and transaction types.', 
            v_account_internal_type, p_type;
    end if;

    -- create the transaction with enhanced error handling
    begin
        insert into data.transactions (
            ledger_id, description, date, amount,
            debit_account_id, credit_account_id, user_data
        )
        values (
            v_ledger_id, v_cleaned_description, p_date, p_amount,
            v_debit_account_id, v_credit_account_id, p_user_data
        )
        returning id into v_transaction_id;
    exception
        when unique_violation then
            raise exception using 
                message = utils.handle_constraint_violation('transactions_uuid_unique', 'transactions'),
                errcode = 'unique_violation';
        when foreign_key_violation then
            raise exception 'Invalid account reference in transaction. Please verify all accounts exist.';
        when check_violation then
            raise exception 'Transaction violates business rules. Please check amount and account constraints.';
    end;

    return v_transaction_id;
end;
$$ language plpgsql security definer;

-- enhance utils.assign_to_category function with better validation
-- keep the original return type to avoid breaking changes
create or replace function utils.assign_to_category(
    p_ledger_uuid text,
    p_date timestamptz,
    p_description text,
    p_amount bigint,
    p_category_uuid text,
    p_user_data text = utils.get_user()
) returns table(r_uuid text, r_description text, r_amount bigint, r_date timestamptz, r_metadata jsonb, r_ledger_uuid text, r_transaction_type text, r_account_uuid text, r_category_uuid text) as
$$
declare
    v_ledger_id          int;
    v_income_account_id  int;
    v_income_account_uuid text;
    v_category_account_id int;
    v_transaction_uuid text;
    v_metadata jsonb;
    v_transaction_record data.transactions;
    v_cleaned_description text;
begin
    -- validate assignment amount and date using new utility function
    perform utils.validate_transaction_data(p_amount, p_date);
    
    -- validate and clean description
    v_cleaned_description := coalesce(trim(p_description), '');
    if char_length(v_cleaned_description) > 500 then
        raise exception 'Assignment description cannot exceed 500 characters. Current length: %', 
            char_length(v_cleaned_description);
    end if;

    -- find the ledger ID for the specified UUID and user
    select l.id into v_ledger_id from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;
    
    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- find the Income account ID and UUID for this ledger
    select a.id, a.uuid into v_income_account_id, v_income_account_uuid 
    from data.accounts a
    where a.ledger_id = v_ledger_id 
      and a.user_data = p_user_data 
      and a.name = 'Income' 
      and a.type = 'equity';
      
    if v_income_account_id is null then
        raise exception 'Income account not found for ledger %. This indicates a system error.', p_ledger_uuid;
    end if;

    -- find the target category account ID with enhanced validation
    select a.id into v_category_account_id from data.accounts a
    where a.uuid = p_category_uuid 
      and a.ledger_id = v_ledger_id 
      and a.user_data = p_user_data 
      and a.type = 'equity';
      
    if v_category_account_id is null then
        raise exception 'Category with UUID % not found in ledger % for current user', 
            p_category_uuid, p_ledger_uuid;
    end if;

    -- create the assignment transaction (debit Income, credit Category)
    begin
        insert into data.transactions (ledger_id, description, date, amount, debit_account_id, credit_account_id, user_data)
        values (v_ledger_id, v_cleaned_description, p_date, p_amount, v_income_account_id, v_category_account_id, p_user_data)
        returning * into v_transaction_record;
    exception
        when unique_violation then
            raise exception using 
                message = utils.handle_constraint_violation('transactions_uuid_unique', 'transactions'),
                errcode = 'unique_violation';
        when foreign_key_violation then
            raise exception 'Invalid account reference in assignment. Please verify all accounts exist.';
    end;

    -- extract values for return
    v_transaction_uuid := v_transaction_record.uuid;
    v_metadata := v_transaction_record.metadata;

    -- return the transaction details in the expected format
    return query select 
        v_transaction_uuid,
        v_cleaned_description,
        p_amount,
        p_date,
        v_metadata,
        p_ledger_uuid,
        null::text, -- transaction_type is null for budget assignments
        v_income_account_uuid,
        p_category_uuid;
end;
$$ language plpgsql security definer;



-- From: 20250824001449_enhance_trigger_functions.sql

-- enhance trigger functions to use our enhanced validation utilities
-- eliminate duplication by making trigger function call our enhanced utils.add_transaction
-- following postgresql conventions with lowercase sql and comments above each step

-- update simple_transactions_insert_fn to use our enhanced utils.add_transaction function
-- this eliminates duplication and ensures consistent validation across all transaction creation paths
create or replace function utils.simple_transactions_insert_fn()
returns trigger as
$$
declare
    v_transaction_id int;
    v_user_data text := utils.get_user();
begin
    -- use our enhanced utils.add_transaction function for all validation and business logic
    -- this ensures consistent validation whether transactions are created via API functions or view inserts
    select utils.add_transaction(
        NEW.ledger_uuid,
        NEW.date::timestamptz,
        NEW.description,
        NEW.type,
        NEW.amount,
        NEW.account_uuid,
        NEW.category_uuid,
        v_user_data
    ) into v_transaction_id;
    
    -- populate NEW record with the created transaction data for backward compatibility
    -- get the transaction details from the created record
    select t.uuid, t.description, t.amount, t.date, t.metadata
      into NEW.uuid, NEW.description, NEW.amount, NEW.date, NEW.metadata
      from data.transactions t
     where t.id = v_transaction_id;
    
    -- NEW.ledger_uuid, NEW.account_uuid, NEW.category_uuid, NEW.type are already set from input
    
    return NEW;
end;
$$ language plpgsql security definer;



-- From: 20250824194010_add_month_view_to_budget_status.sql

-- first, drop all existing api.get_budget_status functions to avoid overloading conflicts
drop function if exists api.get_budget_status(text);
drop function if exists api.get_budget_status(text, text);

-- enhance utils.get_budget_status to support optional date filtering for month view
-- this maintains backward compatibility while adding period-based budget reporting
create or replace function utils.get_budget_status(
    p_ledger_uuid text,
    p_user_data text default utils.get_user(),
    p_start_date date default null,
    p_end_date date default null
) returns table(
    account_uuid text,
    account_name text,
    budgeted decimal,
    activity decimal,
    balance decimal
) as $$
declare
    v_ledger_id bigint;
begin
    -- find the ledger id and validate ownership
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- return budget status for all categories in the ledger
    return query
    with categories as (
        -- get all budget categories (equity accounts except special ones)
        select
            a.id,
            a.uuid,
            a.name
        from
            data.accounts a
        where
            a.ledger_id = v_ledger_id
            and a.user_data = p_user_data
            and a.type = 'equity'
            and a.name not in ('Income', 'Off-budget', 'Unassigned')
    ),
    income_account as (
        -- get the income account id for this ledger
        select a.id
        from data.accounts a
        where a.ledger_id = v_ledger_id
          and a.user_data = p_user_data
          and a.type = 'equity'
          and a.name = 'Income'
        limit 1
    ),
    budget_transactions as (
        -- transactions from income to categories (budget allocations)
        -- apply date filter if provided
        select
            t.credit_account_id as category_id,
            sum(t.amount) as amount
        from
            data.transactions t
        where
            t.ledger_id = v_ledger_id
            and t.user_data = p_user_data
            and t.debit_account_id = (select id from income_account)
            and t.deleted_at is null
            and (p_start_date is null or t.date >= p_start_date)
            and (p_end_date is null or t.date <= p_end_date)
        group by
            t.credit_account_id
    ),
    activity_transactions as (
        -- transactions between categories and asset/liability accounts
        -- apply date filter if provided
        select
            case
                when t.debit_account_id in (select id from categories) then t.debit_account_id
                else t.credit_account_id
            end as category_id,
            sum(
                case
                    when t.debit_account_id in (select id from categories) then -t.amount
                    else t.amount
                end
            ) as amount
        from
            data.transactions t
        where
            t.ledger_id = v_ledger_id
            and t.user_data = p_user_data
            and (
                (t.debit_account_id in (select id from categories) and
                 t.credit_account_id in (select id from data.accounts where ledger_id = v_ledger_id and type in ('asset', 'liability'))) or
                (t.credit_account_id in (select id from categories) and
                 t.debit_account_id in (select id from data.accounts where ledger_id = v_ledger_id and type in ('asset', 'liability')))
            )
            and t.deleted_at is null
            and (p_start_date is null or t.date >= p_start_date)
            and (p_end_date is null or t.date <= p_end_date)
        group by
            case
                when t.debit_account_id in (select id from categories) then t.debit_account_id
                else t.credit_account_id
            end
    )

    -- final result combining all the data
    select
        c.uuid as account_uuid,
        c.name as account_name,
        coalesce(b.amount, 0)::decimal as budgeted,
        coalesce(a.amount, 0)::decimal as activity,
        -- for balance, use all-time balance if no date filter, otherwise calculate period balance
        case 
            when p_start_date is null and p_end_date is null then
                utils.get_account_balance(v_ledger_id, c.id)::decimal
            else
                (coalesce(b.amount, 0) + coalesce(a.amount, 0))::decimal
        end as balance
    from
        categories c
    left join
        budget_transactions b on c.id = b.category_id
    left join
        activity_transactions a on c.id = a.category_id
    order by
        c.name;
end;
$$ language plpgsql;

-- create new api.get_budget_status with optional period parameter
-- period format: YYYYMM (e.g., '202508' for August 2025)
-- maintains backward compatibility with existing calls
create function api.get_budget_status(
    p_ledger_uuid text,
    p_period text default null
) returns table(
    category_uuid text, 
    category_name text, 
    budgeted bigint, 
    activity bigint, 
    balance bigint
) as $$
declare
    v_start_date date;
    v_end_date date;
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
    end if;
    
    -- call the enhanced utils function with date parameters
    return query
    select 
        bs.account_uuid as category_uuid,
        bs.account_name as category_name,
        bs.budgeted::bigint,
        bs.activity::bigint,
        bs.balance::bigint
    from utils.get_budget_status(p_ledger_uuid, utils.get_user(), v_start_date, v_end_date) bs;
end;
$$ language plpgsql;



-- From: 20250824201756_enhance_budget_status_with_income_summary.sql

-- create utils function to get income transactions with optional period filtering
-- this respects the same date filtering as budget_status for consistency
create function utils.get_income_total(
    p_ledger_uuid text,
    p_user_data text default utils.get_user(),
    p_start_date date default null,
    p_end_date date default null
) returns bigint as $$
declare
    v_ledger_id bigint;
    v_income_total bigint;
begin
    -- find the ledger id and validate ownership
    select l.id into v_ledger_id
    from data.ledgers l
    where l.uuid = p_ledger_uuid and l.user_data = p_user_data;

    if v_ledger_id is null then
        raise exception 'Ledger with UUID % not found for current user', p_ledger_uuid;
    end if;

    -- calculate total income for the period
    -- income transactions are those that credit the Income account from asset/liability accounts
    select coalesce(sum(t.amount), 0) into v_income_total
    from data.transactions t
    join data.accounts income_acc on t.credit_account_id = income_acc.id
    join data.accounts source_acc on t.debit_account_id = source_acc.id
    where t.ledger_id = v_ledger_id
      and t.user_data = p_user_data
      and t.deleted_at is null
      and income_acc.name = 'Income'
      and income_acc.type = 'equity'
      and source_acc.type in ('asset', 'liability')
      and (p_start_date is null or t.date >= p_start_date)
      and (p_end_date is null or t.date <= p_end_date);

    return v_income_total;
end;
$$ language plpgsql;

-- create new api function for budget totals
-- returns: income, income_remaining_from_last_month, budgeted, left_to_budget
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



-- From: 20250824214953_add_groups_table.sql

-- creates the groups table to organize categories into logical groups.
create table data.groups
(
    id          bigint generated always as identity primary key,
    uuid        text        not null default utils.nanoid(8),

    created_at  timestamptz not null default current_timestamp,
    updated_at  timestamptz not null default current_timestamp,

    name        text        not null,
    description text,
    sort_order  integer     not null default 0,
    metadata    jsonb,
    user_data   text        not null default utils.get_user(),

    -- links the group to a ledger. groups are deleted if the parent ledger is deleted.
    ledger_id   bigint      not null references data.ledgers (id) on delete cascade,

    -- constraints
    constraint groups_uuid_unique unique (uuid),
    constraint groups_name_ledger_unique unique (name, ledger_id, user_data),
    constraint groups_name_length_check check (char_length(name) <= 255),
    constraint groups_user_data_length_check check (char_length(user_data) <= 255),
    constraint groups_description_length_check check (char_length(description) <= 255)
);

-- enables row level security (rls) on the data.groups table.
alter table data.groups
    enable row level security;

-- creates an rls policy on data.groups to ensure users can only access and modify their own groups.
create policy groups_policy on data.groups
    using (user_data = utils.get_user())
    with check (user_data = utils.get_user());

comment on policy groups_policy on data.groups is 'Ensures that users can only access and modify their own groups based on the user_data column.';

-- creates an index on ledger_id for efficient queries.
create index groups_ledger_id_idx on data.groups (ledger_id);

-- creates an index on sort_order for efficient ordering.
create index groups_sort_order_idx on data.groups (sort_order);



-- From: 20250824220136_add_group_id_to_categories.sql

-- adds group_id column to accounts table to link category accounts to groups.
-- only applies to accounts with type = 'equity' (categories)
alter table data.accounts
    add column group_id bigint references data.groups (id) on delete set null;

-- creates an index on group_id for efficient queries.
create index accounts_group_id_idx on data.accounts (group_id);



-- From: 20250824220411_add_group_api_functions.sql

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



-- Set version
INSERT INTO utils.metadata (key, value) VALUES ('version', 'v0.4.0') ON CONFLICT (key) DO UPDATE SET value = 'v0.4.0';
