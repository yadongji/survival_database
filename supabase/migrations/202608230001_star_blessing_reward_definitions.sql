begin;

create table public.star_blessing_reward_definition_sets (
    definition_version integer primary key check (definition_version > 0),
    definition_hash text not null check (definition_hash ~ '^[0-9a-f]{64}$'),
    activated_at timestamptz not null default now()
);

create table public.star_blessing_reward_definitions (
    definition_version integer not null references public.star_blessing_reward_definition_sets(definition_version),
    reward_id text not null check (reward_id ~ '^star_blessing_[A-Za-z0-9_.:-]+$'),
    display_name text not null,
    weight numeric not null check (weight > 0),
    effect_key text not null,
    effect_scope text not null check (effect_scope = 'permanent'),
    value_min numeric not null check (value_min >= 0),
    value_max numeric not null check (value_max >= value_min),
    stacking_rule text not null check (stacking_rule in ('add', 'max')),
    cap_value numeric,
    primary key (definition_version, reward_id)
);

create trigger star_blessing_reward_definition_sets_immutable
before update or delete on public.star_blessing_reward_definition_sets
for each row execute function public.reject_fishing_immutable_mutation();
create trigger star_blessing_reward_definitions_immutable
before update or delete on public.star_blessing_reward_definitions
for each row execute function public.reject_fishing_immutable_mutation();

alter table public.star_blessing_reward_definition_sets enable row level security;
alter table public.star_blessing_reward_definitions enable row level security;
revoke all on table public.star_blessing_reward_definition_sets,
    public.star_blessing_reward_definitions from public, anon, authenticated;

create or replace function public.sync_star_blessing_reward_definitions(
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
    v_expected_count integer;
    v_inserted_count integer;
begin
    if p_definition_version < 1
        or p_definition_hash !~ '^[0-9a-f]{64}$'
        or jsonb_typeof(p_definitions) <> 'array'
        or jsonb_array_length(p_definitions) < 1 then
        raise exception 'definition_payload_invalid';
    end if;
    if exists (
        select 1 from jsonb_to_recordset(p_definitions) as d(
            reward_id text, display_name text, weight numeric, effect_key text,
            effect_scope text, value_min numeric, value_max numeric,
            stacking_rule text, cap_value numeric
        ) where d.reward_id !~ '^star_blessing_[A-Za-z0-9_.:-]+$'
            or d.display_name is null or d.display_name = ''
            or d.weight is null or d.weight <= 0
            or d.effect_key is null or d.effect_key = ''
            or d.effect_scope <> 'permanent'
            or d.value_min is null or d.value_min < 0
            or d.value_max is null or d.value_max < d.value_min
            or d.stacking_rule not in ('add', 'max')
    ) then
        raise exception 'definition_row_invalid';
    end if;
    v_expected_count := jsonb_array_length(p_definitions);
    if (select count(distinct d.reward_id)
        from jsonb_to_recordset(p_definitions) as d(reward_id text)) <> v_expected_count then
        raise exception 'definition_reward_id_duplicate';
    end if;

    select definition_hash into v_existing_hash
    from public.star_blessing_reward_definition_sets
    where definition_version = p_definition_version;
    if v_existing_hash is not null then
        if v_existing_hash <> p_definition_hash then
            raise exception 'definition_version_hash_conflict';
        end if;
        select count(*) into v_inserted_count
        from public.star_blessing_reward_definitions
        where definition_version = p_definition_version;
        if v_inserted_count <> v_expected_count then
            raise exception 'definition_version_row_conflict';
        end if;
        return jsonb_build_object('ok', true, 'duplicate', true,
            'definition_version', p_definition_version, 'row_count', v_inserted_count);
    end if;

    insert into public.star_blessing_reward_definition_sets(
        definition_version, definition_hash
    ) values (p_definition_version, p_definition_hash);
    insert into public.star_blessing_reward_definitions(
        definition_version, reward_id, display_name, weight, effect_key,
        effect_scope, value_min, value_max, stacking_rule, cap_value
    ) select p_definition_version, d.reward_id, d.display_name, d.weight,
        d.effect_key, d.effect_scope, d.value_min, d.value_max,
        d.stacking_rule, d.cap_value
    from jsonb_to_recordset(p_definitions) as d(
        reward_id text, display_name text, weight numeric, effect_key text,
        effect_scope text, value_min numeric, value_max numeric,
        stacking_rule text, cap_value numeric
    );
    get diagnostics v_inserted_count = row_count;
    return jsonb_build_object('ok', true, 'duplicate', false,
        'definition_version', p_definition_version, 'row_count', v_inserted_count);
end;
$$;

-- Recompile every grant path against the new tables before removing the legacy
-- definition schema. No legacy definition row is copied: CSV synchronization is
-- the only source allowed to publish a star blessing definition set.
do $$
declare
    v_signature regprocedure;
    v_definition text;
begin
    foreach v_signature in array array[
        'public.grant_out_of_match_reward(text,uuid,text,integer,numeric)'::regprocedure,
        'public.checkpoint_online_time(text,text,text,integer,integer,integer,integer)'::regprocedure,
        'public.heartbeat_fishing_session(text,text,text,integer,integer,integer,integer)'::regprocedure
    ] loop
        v_definition := pg_get_functiondef(v_signature);
        if position('fishing_reward_definitions' in v_definition) = 0
            or position('fishing_reward_definition_sets' in v_definition) = 0 then
            raise exception 'legacy_definition_dependency_missing: %', v_signature;
        end if;
        v_definition := replace(v_definition,
            'public.fishing_reward_definitions',
            'public.star_blessing_reward_definitions');
        v_definition := replace(v_definition,
            'public.fishing_reward_definition_sets',
            'public.star_blessing_reward_definition_sets');
        execute v_definition;
    end loop;
end;
$$;

alter function public.grant_out_of_match_reward(text, uuid, text, integer, numeric)
    set search_path = public, extensions;

alter table public.fishing_states
    drop constraint fishing_states_definition_version_fkey;
alter table public.fishing_states
    add constraint fishing_states_definition_version_fkey
    foreign key (definition_version)
    references public.star_blessing_reward_definition_sets(definition_version)
    not valid;

revoke all on function public.sync_star_blessing_reward_definitions(integer, text, jsonb) from public;
grant execute on function public.sync_star_blessing_reward_definitions(integer, text, jsonb) to service_role;
drop function public.sync_fishing_reward_definitions(integer, text, jsonb);
drop table public.fishing_reward_definitions;
drop table public.fishing_reward_definition_sets;

commit;