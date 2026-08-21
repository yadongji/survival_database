begin;

create extension if not exists pgcrypto;

create table if not exists public.survival_players (
    account_id text primary key check (account_id ~ '^[0-9a-f]{64}$'),
    profile_revision bigint not null default 0 check (profile_revision >= 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.fishing_reward_definition_sets (
    definition_version integer primary key check (definition_version > 0),
    definition_hash text not null check (definition_hash ~ '^[0-9a-f]{64}$'),
    activated_at timestamptz not null default now()
);

create table if not exists public.fishing_reward_definitions (
    definition_version integer not null references public.fishing_reward_definition_sets(definition_version),
    reward_id text not null,
    display_name text not null,
    weight numeric not null check (weight > 0),
    effect_key text not null,
    effect_scope text not null check (effect_scope in ('immediate', 'permanent')),
    value_min numeric not null check (value_min = trunc(value_min)),
    value_max numeric not null check (
        value_max = trunc(value_max) and value_max >= value_min
    ),
    stacking_rule text not null check (stacking_rule in ('add', 'max')),
    cap_value numeric,
    primary key (definition_version, reward_id)
);

create table if not exists public.fishing_states (
    account_id text primary key references public.survival_players(account_id) on delete cascade,
    remaining_seconds numeric not null check (remaining_seconds >= 0),
    definition_version integer not null references public.fishing_reward_definition_sets(definition_version),
    last_grant_at timestamptz,
    updated_at timestamptz not null default now()
);

create table if not exists public.fishing_sessions (
    session_id text primary key,
    account_id text not null references public.survival_players(account_id) on delete cascade,
    last_heartbeat_at timestamptz not null default now(),
    created_at timestamptz not null default now()
);
create index if not exists fishing_sessions_account_idx
    on public.fishing_sessions(account_id);
create unique index if not exists fishing_sessions_one_per_account_idx
    on public.fishing_sessions(account_id);

create table if not exists public.reward_grants (
    grant_id uuid primary key default gen_random_uuid(),
    account_id text not null references public.survival_players(account_id) on delete cascade,
    reward_id text not null,
    effect_key text not null,
    effect_scope text not null check (effect_scope in ('immediate', 'permanent')),
    amount numeric not null,
    definition_version integer not null,
    definition_hash text not null,
    granted_at timestamptz not null default now()
);
create index if not exists reward_grants_account_time_idx
    on public.reward_grants(account_id, granted_at desc);

create table if not exists public.player_effect_totals (
    account_id text not null references public.survival_players(account_id) on delete cascade,
    effect_key text not null,
    total_value numeric not null,
    updated_at timestamptz not null default now(),
    primary key (account_id, effect_key)
);

create table if not exists public.fishing_idempotency (
    request_id text primary key,
    account_id text not null references public.survival_players(account_id) on delete cascade,
    response jsonb not null,
    created_at timestamptz not null default now()
);
create index if not exists fishing_idempotency_created_idx
    on public.fishing_idempotency(created_at);

create or replace function public.reject_fishing_immutable_mutation()
returns trigger
language plpgsql
as $$
begin
    raise exception 'fishing_immutable_row';
end;
$$;

drop trigger if exists fishing_definition_sets_immutable
    on public.fishing_reward_definition_sets;
create trigger fishing_definition_sets_immutable
before update or delete on public.fishing_reward_definition_sets
for each row execute function public.reject_fishing_immutable_mutation();

drop trigger if exists fishing_definitions_immutable
    on public.fishing_reward_definitions;
create trigger fishing_definitions_immutable
before update or delete on public.fishing_reward_definitions
for each row execute function public.reject_fishing_immutable_mutation();

drop trigger if exists reward_grants_immutable on public.reward_grants;
create trigger reward_grants_immutable
before update or delete on public.reward_grants
for each row execute function public.reject_fishing_immutable_mutation();

alter table public.survival_players enable row level security;
alter table public.fishing_reward_definition_sets enable row level security;
alter table public.fishing_reward_definitions enable row level security;
alter table public.fishing_states enable row level security;
alter table public.fishing_sessions enable row level security;
alter table public.reward_grants enable row level security;
alter table public.player_effect_totals enable row level security;
alter table public.fishing_idempotency enable row level security;

create or replace function public.fishing_profile_json(p_account_id text)
returns jsonb
language sql
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'schema_version', 1,
        'account_id', p.account_id,
        'revision', p.profile_revision,
        'entitlements', '{}'::jsonb,
        'achievements', '{}'::jsonb,
        'save', jsonb_build_object(
            'fishing', coalesce((
                select jsonb_build_object(
                    'remaining_seconds', floor(s.remaining_seconds),
                    'definition_version', s.definition_version
                ) from public.fishing_states s where s.account_id = p.account_id
            ), '{}'::jsonb),
            'permanent_effects', coalesce((
                select jsonb_object_agg(e.effect_key, e.total_value)
                from public.player_effect_totals e where e.account_id = p.account_id
            ), '{}'::jsonb)
        ),
        'public', '{}'::jsonb
    )
    from public.survival_players p
    where p.account_id = p_account_id;
$$;

create or replace function public.get_fishing_profile(p_account_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_result jsonb;
begin
    if p_account_id is null or p_account_id !~ '^[0-9a-f]{64}$' then
        raise exception 'account_id_invalid';
    end if;
    insert into public.survival_players(account_id) values (p_account_id)
    on conflict (account_id) do nothing;
    select public.fishing_profile_json(p_account_id) into v_result;
    return v_result;
end;
$$;

create or replace function public.sync_fishing_reward_definitions(
    p_definition_version integer,
    p_definition_hash text,
    p_definitions jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_existing_hash text;
    v_count integer;
begin
    if p_definition_version <= 0 or p_definition_hash !~ '^[0-9a-f]{64}$'
        or jsonb_typeof(p_definitions) <> 'array' then
        raise exception 'definition_payload_invalid';
    end if;
    select definition_hash into v_existing_hash
    from public.fishing_reward_definition_sets
    where definition_version = p_definition_version;
    if v_existing_hash is not null and v_existing_hash <> p_definition_hash then
        raise exception 'definition_version_hash_conflict';
    end if;
    if v_existing_hash is not null then
        select count(*) into v_count from public.fishing_reward_definitions
        where definition_version = p_definition_version;
        if v_count = 0 then raise exception 'enabled_definition_missing'; end if;
        return jsonb_build_object('ok', true, 'count', v_count,
            'definition_version', p_definition_version,
            'definition_hash', p_definition_hash, 'existing', true);
    end if;
    insert into public.fishing_reward_definition_sets(definition_version, definition_hash)
    values (p_definition_version, p_definition_hash)
    on conflict (definition_version) do nothing;
    insert into public.fishing_reward_definitions(
        definition_version, reward_id, display_name, weight, effect_key,
        effect_scope, value_min, value_max, stacking_rule, cap_value
    )
    select p_definition_version, x.reward_id, x.display_name, x.weight,
        x.effect_key, x.effect_scope, x.value_min, x.value_max,
        x.stacking_rule, x.cap_value
    from jsonb_to_recordset(p_definitions) as x(
        reward_id text, display_name text, weight numeric, effect_key text,
        effect_scope text, value_min numeric, value_max numeric,
        stacking_rule text, cap_value numeric
    )
    on conflict (definition_version, reward_id) do nothing;
    select count(*) into v_count from public.fishing_reward_definitions
    where definition_version = p_definition_version;
    if v_count = 0 then raise exception 'enabled_definition_missing'; end if;
    return jsonb_build_object('ok', true, 'count', v_count,
        'definition_version', p_definition_version, 'definition_hash', p_definition_hash);
end;
$$;

create or replace function public.heartbeat_fishing_session(
    p_account_id text,
    p_session_id text,
    p_request_id text,
    p_definition_version integer,
    p_heartbeat_lease_seconds integer,
    p_interval_min_seconds integer,
    p_interval_max_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_now timestamptz := clock_timestamp();
    v_previous timestamptz;
    v_previous_session_id text;
    v_elapsed numeric := 0;
    v_remaining numeric;
    v_definition_hash text;
    v_reward public.fishing_reward_definitions%rowtype;
    v_amount numeric;
    v_grant_id uuid;
    v_response jsonb;
begin
    if p_account_id is null or p_account_id !~ '^[0-9a-f]{64}$'
        or p_session_id is null or length(p_session_id) < 8
        or p_request_id is null or length(p_request_id) < 8
        or p_heartbeat_lease_seconds < 1
        or p_interval_min_seconds < 1
        or p_interval_max_seconds < p_interval_min_seconds then
        raise exception 'heartbeat_payload_invalid';
    end if;
    select response into v_response from public.fishing_idempotency
    where request_id = p_request_id and account_id = p_account_id;
    if v_response is not null then return v_response; end if;

    insert into public.survival_players(account_id) values (p_account_id)
    on conflict (account_id) do nothing;
    perform 1 from public.survival_players where account_id = p_account_id for update;
    select response into v_response from public.fishing_idempotency
    where request_id = p_request_id and account_id = p_account_id;
    if v_response is not null then return v_response; end if;
    select definition_hash into v_definition_hash
    from public.fishing_reward_definition_sets
    where definition_version = p_definition_version;
    if v_definition_hash is null then raise exception 'definition_version_missing'; end if;

    select session_id, last_heartbeat_at into v_previous_session_id, v_previous
    from public.fishing_sessions
    where account_id = p_account_id for update;
    if found and v_previous_session_id <> p_session_id
        and extract(epoch from (v_now - v_previous)) between 0 and p_heartbeat_lease_seconds then
        raise exception 'fishing_session_active';
    end if;
    if found and v_previous_session_id = p_session_id
        and extract(epoch from (v_now - v_previous)) between 0 and p_heartbeat_lease_seconds then
        v_elapsed := extract(epoch from (v_now - v_previous));
    end if;
    insert into public.fishing_sessions(session_id, account_id, last_heartbeat_at)
    values (p_session_id, p_account_id, v_now)
    on conflict (account_id) do update set
        session_id = excluded.session_id,
        last_heartbeat_at = excluded.last_heartbeat_at;

    select remaining_seconds into v_remaining from public.fishing_states
    where account_id = p_account_id for update;
    if not found then
        v_remaining := p_interval_min_seconds
            + floor(random() * (p_interval_max_seconds - p_interval_min_seconds + 1));
        insert into public.fishing_states(account_id, remaining_seconds, definition_version)
        values (p_account_id, v_remaining, p_definition_version);
    end if;
    v_remaining := greatest(0, v_remaining - v_elapsed);

    if v_remaining <= 0 then
        select d.* into v_reward
        from public.fishing_reward_definitions d
        where d.definition_version = p_definition_version
        order by -ln(greatest(random(), 0.0000000001)) / d.weight
        limit 1;
        if not found then raise exception 'enabled_definition_missing'; end if;
        v_amount := v_reward.value_min + floor(random() * (v_reward.value_max - v_reward.value_min + 1));
        insert into public.reward_grants(
            account_id, reward_id, effect_key, effect_scope, amount,
            definition_version, definition_hash
        ) values (
            p_account_id, v_reward.reward_id, v_reward.effect_key,
            v_reward.effect_scope, v_amount, p_definition_version, v_definition_hash
        ) returning grant_id into v_grant_id;
        if v_reward.effect_scope = 'permanent' then
            insert into public.player_effect_totals(account_id, effect_key, total_value)
            values (p_account_id, v_reward.effect_key, v_amount)
            on conflict (account_id, effect_key) do update set
                total_value = case
                    when v_reward.stacking_rule = 'max' then greatest(
                        public.player_effect_totals.total_value, excluded.total_value)
                    else public.player_effect_totals.total_value + excluded.total_value
                end,
                updated_at = v_now;
            if v_reward.cap_value is not null and v_reward.cap_value > 0 then
                update public.player_effect_totals set total_value = least(total_value, v_reward.cap_value)
                where account_id = p_account_id and effect_key = v_reward.effect_key;
            end if;
        end if;
        update public.survival_players set profile_revision = profile_revision + 1,
            updated_at = v_now where account_id = p_account_id;
        v_remaining := p_interval_min_seconds
            + floor(random() * (p_interval_max_seconds - p_interval_min_seconds + 1));
    end if;

    update public.fishing_states set remaining_seconds = v_remaining,
        definition_version = p_definition_version,
        last_grant_at = case when v_grant_id is not null then v_now else last_grant_at end,
        updated_at = v_now where account_id = p_account_id;
    v_response := jsonb_build_object(
        'ok', true,
        'elapsed_seconds', floor(v_elapsed),
        'remaining_seconds', floor(v_remaining),
        'profile', public.fishing_profile_json(p_account_id),
        'grant', case when v_grant_id is null then null else jsonb_build_object(
            'grant_id', v_grant_id, 'reward_id', v_reward.reward_id,
            'display_name', v_reward.display_name, 'effect_key', v_reward.effect_key,
            'effect_scope', v_reward.effect_scope, 'amount', v_amount,
            'definition_version', p_definition_version, 'definition_hash', v_definition_hash
        ) end
    );
    insert into public.fishing_idempotency(request_id, account_id, response)
    values (p_request_id, p_account_id, v_response);
    return v_response;
exception when unique_violation then
    select response into v_response from public.fishing_idempotency
    where request_id = p_request_id and account_id = p_account_id;
    if v_response is not null then return v_response; end if;
    raise;
end;
$$;

revoke all on table public.survival_players from anon, authenticated;
revoke all on table public.fishing_reward_definition_sets from anon, authenticated;
revoke all on table public.fishing_reward_definitions from anon, authenticated;
revoke all on table public.fishing_states from anon, authenticated;
revoke all on table public.fishing_sessions from anon, authenticated;
revoke all on table public.reward_grants from anon, authenticated;
revoke all on table public.player_effect_totals from anon, authenticated;
revoke all on table public.fishing_idempotency from anon, authenticated;
revoke all on function public.fishing_profile_json(text) from public;
revoke all on function public.reject_fishing_immutable_mutation() from public;
revoke all on function public.get_fishing_profile(text) from public;
revoke all on function public.sync_fishing_reward_definitions(integer, text, jsonb) from public;
revoke all on function public.heartbeat_fishing_session(text, text, text, integer, integer, integer, integer) from public;
grant execute on function public.get_fishing_profile(text) to service_role;
grant execute on function public.sync_fishing_reward_definitions(integer, text, jsonb) to service_role;
grant execute on function public.heartbeat_fishing_session(text, text, text, integer, integer, integer, integer) to service_role;

commit;