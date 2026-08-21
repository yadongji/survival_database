begin;

create table if not exists public.player_gameplay_stats (
    player_id text primary key references public.survival_players(account_id) on delete cascade,
    initial_wood bigint not null check (initial_wood >= 0),
    initial_gold bigint not null check (initial_gold >= 0),
    wood_per_second numeric(20,6) not null check (wood_per_second >= 0),
    lumberjack_attack_efficiency bigint not null check (lumberjack_attack_efficiency >= 0),
    gold_per_second numeric(20,6) not null check (gold_per_second >= 0),
    gold_mine_efficiency_pct numeric(20,6) not null check (gold_mine_efficiency_pct between 0 and 10000),
    initial_population_cap bigint not null check (initial_population_cap >= 0),
    starjoy_points bigint not null check (starjoy_points >= 0),
    hero_initial_attack bigint not null check (hero_initial_attack >= 0),
    hero_damage_attack_growth numeric(20,6) not null check (hero_damage_attack_growth >= 0),
    hero_basic_attack_growth numeric(20,6) not null check (hero_basic_attack_growth >= 0),
    hero_final_damage_bonus_pct numeric(20,6) not null check (hero_final_damage_bonus_pct between 0 and 10000),
    hero_attack_armor_reduction numeric(20,6) not null check (hero_attack_armor_reduction >= 0),
    hero_attribute_growth numeric(20,6) not null check (hero_attribute_growth >= 0),
    hero_critical_damage_bonus_pct numeric(20,6) not null check (hero_critical_damage_bonus_pct between 0 and 10000),
    hero_attack_bonus_pct numeric(20,6) not null check (hero_attack_bonus_pct between 0 and 10000),
    hero_health_bonus_pct numeric(20,6) not null check (hero_health_bonus_pct between 0 and 10000),
    hero_armor_bonus_pct numeric(20,6) not null check (hero_armor_bonus_pct between 0 and 10000),
    hero_damage_reduction_pct numeric(20,6) not null check (hero_damage_reduction_pct between 0 and 100),
    tower_attack_bonus_pct numeric(20,6) not null check (tower_attack_bonus_pct between 0 and 10000),
    tower_attack_speed_bonus_pct numeric(20,6) not null check (tower_attack_speed_bonus_pct between 0 and 10000),
    tower_attack_armor_reduction numeric(20,6) not null check (tower_attack_armor_reduction >= 0),
    tower_critical_chance_pct numeric(20,6) not null check (tower_critical_chance_pct between 0 and 100),
    tower_attack_interval numeric(20,6) not null check (tower_attack_interval > 0),
    tower_final_damage_bonus_pct numeric(20,6) not null check (tower_final_damage_bonus_pct between 0 and 10000),
    wall_damage_block numeric(20,6) not null check (wall_damage_block >= 0),
    wall_damage_reduction_pct numeric(20,6) not null check (wall_damage_reduction_pct between 0 and 100),
    wall_armor_bonus_pct numeric(20,6) not null check (wall_armor_bonus_pct between 0 and 10000),
    wall_health_regen_per_second numeric(20,6) not null check (wall_health_regen_per_second >= 0),
    wall_initial_health bigint not null check (wall_initial_health >= 0),
    wall_armor numeric(20,6) not null check (wall_armor >= 0),
    wall_health_bonus_pct numeric(20,6) not null check (wall_health_bonus_pct between 0 and 10000),
    wall_health_per_second numeric(20,6) not null check (wall_health_per_second >= 0),
    lumberjack_attack_growth numeric(20,6) not null check (lumberjack_attack_growth >= 0),
    lumberjack_attack_speed_bonus_pct numeric(20,6) not null check (lumberjack_attack_speed_bonus_pct between 0 and 10000),
    online_seconds_total bigint not null default 0 check (online_seconds_total >= 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.player_gameplay_stats
    add column if not exists online_seconds_total bigint not null default 0
    check (online_seconds_total >= 0);

alter table public.player_gameplay_stats enable row level security;
revoke all on table public.player_gameplay_stats from anon, authenticated;

create or replace function public.ensure_player_gameplay_stats(
    p_account_id text,
    p_gameplay_stats jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_stats public.player_gameplay_stats%rowtype;
begin
    if p_account_id is null or p_account_id !~ '^[0-9a-f]{64}$'
        or p_gameplay_stats is null or jsonb_typeof(p_gameplay_stats) <> 'object' then
        raise exception 'gameplay_stats_payload_invalid';
    end if;
    insert into public.survival_players(account_id) values (p_account_id)
    on conflict (account_id) do nothing;
    insert into public.player_gameplay_stats(
        player_id, initial_wood, initial_gold, wood_per_second,
        lumberjack_attack_efficiency, gold_per_second, gold_mine_efficiency_pct,
        initial_population_cap, starjoy_points, hero_initial_attack,
        hero_damage_attack_growth, hero_basic_attack_growth,
        hero_final_damage_bonus_pct, hero_attack_armor_reduction,
        hero_attribute_growth, hero_critical_damage_bonus_pct, hero_attack_bonus_pct,
        hero_health_bonus_pct, hero_armor_bonus_pct, hero_damage_reduction_pct,
        tower_attack_bonus_pct, tower_attack_speed_bonus_pct,
        tower_attack_armor_reduction, tower_critical_chance_pct,
        tower_attack_interval, tower_final_damage_bonus_pct, wall_damage_block,
        wall_damage_reduction_pct, wall_armor_bonus_pct, wall_health_regen_per_second,
        wall_initial_health, wall_armor, wall_health_bonus_pct, wall_health_per_second,
        lumberjack_attack_growth, lumberjack_attack_speed_bonus_pct,
        online_seconds_total
    )
    select p_account_id, x.initial_wood, x.initial_gold, x.wood_per_second,
        x.lumberjack_attack_efficiency, x.gold_per_second, x.gold_mine_efficiency_pct,
        x.initial_population_cap, x.starjoy_points, x.hero_initial_attack,
        x.hero_damage_attack_growth, x.hero_basic_attack_growth,
        x.hero_final_damage_bonus_pct, x.hero_attack_armor_reduction,
        x.hero_attribute_growth, x.hero_critical_damage_bonus_pct, x.hero_attack_bonus_pct,
        x.hero_health_bonus_pct, x.hero_armor_bonus_pct, x.hero_damage_reduction_pct,
        x.tower_attack_bonus_pct, x.tower_attack_speed_bonus_pct,
        x.tower_attack_armor_reduction, x.tower_critical_chance_pct,
        x.tower_attack_interval, x.tower_final_damage_bonus_pct, x.wall_damage_block,
        x.wall_damage_reduction_pct, x.wall_armor_bonus_pct, x.wall_health_regen_per_second,
        x.wall_initial_health, x.wall_armor, x.wall_health_bonus_pct, x.wall_health_per_second,
        x.lumberjack_attack_growth, x.lumberjack_attack_speed_bonus_pct,
        coalesce(x.online_seconds_total, 0)
    from jsonb_to_record(p_gameplay_stats) as x(
        initial_wood bigint, initial_gold bigint, wood_per_second numeric,
        lumberjack_attack_efficiency bigint, gold_per_second numeric,
        gold_mine_efficiency_pct numeric, initial_population_cap bigint,
        starjoy_points bigint, hero_initial_attack bigint,
        hero_damage_attack_growth numeric, hero_basic_attack_growth numeric,
        hero_final_damage_bonus_pct numeric, hero_attack_armor_reduction numeric,
        hero_attribute_growth numeric, hero_critical_damage_bonus_pct numeric,
        hero_attack_bonus_pct numeric, hero_health_bonus_pct numeric,
        hero_armor_bonus_pct numeric, hero_damage_reduction_pct numeric,
        tower_attack_bonus_pct numeric, tower_attack_speed_bonus_pct numeric,
        tower_attack_armor_reduction numeric, tower_critical_chance_pct numeric,
        tower_attack_interval numeric, tower_final_damage_bonus_pct numeric,
        wall_damage_block numeric, wall_damage_reduction_pct numeric,
        wall_armor_bonus_pct numeric, wall_health_regen_per_second numeric,
        wall_initial_health bigint, wall_armor numeric, wall_health_bonus_pct numeric,
        wall_health_per_second numeric, lumberjack_attack_growth numeric,
        lumberjack_attack_speed_bonus_pct numeric, online_seconds_total bigint
    )
    on conflict (player_id) do nothing;
    select * into v_stats from public.player_gameplay_stats where player_id = p_account_id;
    return to_jsonb(v_stats);
end;
$$;

grant execute on function public.ensure_player_gameplay_stats(text, jsonb) to service_role;

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
    v_profile_changed boolean := false;
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

    if floor(v_elapsed) > 0 then
        update public.player_gameplay_stats
        set online_seconds_total = online_seconds_total + floor(v_elapsed),
            updated_at = v_now
        where player_id = p_account_id;
        if not found then raise exception 'gameplay_stats_missing'; end if;
        v_profile_changed := true;
    end if;

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
        v_profile_changed := true;
        v_remaining := p_interval_min_seconds
            + floor(random() * (p_interval_max_seconds - p_interval_min_seconds + 1));
    end if;

    if v_profile_changed then
        update public.survival_players set profile_revision = profile_revision + 1,
            updated_at = v_now where account_id = p_account_id;
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

revoke all on function public.heartbeat_fishing_session(text, text, text, integer, integer, integer, integer) from public;
grant execute on function public.heartbeat_fishing_session(text, text, text, integer, integer, integer, integer) to service_role;

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
            ), '{}'::jsonb),
            'gameplay_stats', coalesce((
                select to_jsonb(gs) - 'player_id' - 'created_at' - 'updated_at'
                from public.player_gameplay_stats gs where gs.player_id = p.account_id
            ), '{}'::jsonb)
        ),
        'public', '{}'::jsonb
    )
    from public.survival_players p
    where p.account_id = p_account_id;
$$;

revoke all on function public.ensure_player_gameplay_stats(text, jsonb) from public;
grant execute on function public.ensure_player_gameplay_stats(text, jsonb) to service_role;

commit;