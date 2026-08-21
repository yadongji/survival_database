begin;

create table if not exists public.online_time_sessions (
    account_id text primary key references public.survival_players(account_id) on delete cascade,
    session_id text not null,
    last_checkpoint_at timestamptz not null,
    updated_at timestamptz not null default now()
);

create table if not exists public.online_time_idempotency (
    request_id text primary key,
    account_id text not null references public.survival_players(account_id) on delete cascade,
    response jsonb not null,
    created_at timestamptz not null default now()
);

alter table public.online_time_sessions enable row level security;
alter table public.online_time_idempotency enable row level security;
revoke all on table public.online_time_sessions, public.online_time_idempotency from public, anon, authenticated;

create or replace function public.checkpoint_online_time(
    p_account_id text,
    p_session_id text,
    p_request_id text,
    p_lease_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_now timestamptz := clock_timestamp();
    v_previous timestamptz;
    v_previous_session text;
    v_elapsed bigint := 0;
    v_response jsonb;
begin
    if p_account_id is null or p_account_id !~ '^[0-9a-f]{64}$'
        or p_session_id is null or length(p_session_id) < 8
        or p_request_id is null or length(p_request_id) < 8
        or p_lease_seconds < 1 then
        raise exception 'online_time_payload_invalid';
    end if;
    select response into v_response from public.online_time_idempotency
        where request_id = p_request_id and account_id = p_account_id;
    if v_response is not null then return v_response; end if;

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
        tower_attack_armor_reduction, tower_critical_chance_pct, tower_attack_interval,
        tower_final_damage_bonus_pct, wall_damage_block, wall_damage_reduction_pct,
        wall_armor_bonus_pct, wall_health_regen_per_second, wall_initial_health,
        wall_armor, wall_health_bonus_pct, wall_health_per_second,
        lumberjack_attack_growth, lumberjack_attack_speed_bonus_pct
    ) select p_account_id, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    where not exists (select 1 from public.player_gameplay_stats where player_id = p_account_id);

    perform 1 from public.player_gameplay_stats where player_id = p_account_id for update;
    select session_id, last_checkpoint_at into v_previous_session, v_previous
        from public.online_time_sessions where account_id = p_account_id for update;
    if found and v_previous_session = p_session_id
        and extract(epoch from (v_now - v_previous)) between 0 and p_lease_seconds then
        v_elapsed := floor(extract(epoch from (v_now - v_previous)));
        update public.player_gameplay_stats set online_seconds_total =
            online_seconds_total + v_elapsed, updated_at = v_now
            where player_id = p_account_id;
    end if;
    insert into public.online_time_sessions(account_id, session_id, last_checkpoint_at)
        values (p_account_id, p_session_id, v_now)
        on conflict (account_id) do update set session_id = excluded.session_id,
            last_checkpoint_at = excluded.last_checkpoint_at, updated_at = v_now;
    v_response := jsonb_build_object('ok', true, 'elapsed_seconds', v_elapsed);
    insert into public.online_time_idempotency(request_id, account_id, response)
        values (p_request_id, p_account_id, v_response);
    return v_response;
exception when unique_violation then
    select response into v_response from public.online_time_idempotency
        where request_id = p_request_id and account_id = p_account_id;
    if v_response is not null then return v_response; end if;
    raise;
end;
$$;

revoke all on function public.checkpoint_online_time(text, text, text, integer) from public;
grant execute on function public.checkpoint_online_time(text, text, text, integer) to service_role;

commit;