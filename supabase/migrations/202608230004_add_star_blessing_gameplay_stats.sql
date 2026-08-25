begin;

alter table public.player_gameplay_stats
    add column if not exists hero_attributes_per_second numeric(20,6) not null default 0
        check (hero_attributes_per_second >= 0),
    add column if not exists tower_attack_per_second numeric(20,6) not null default 0
        check (tower_attack_per_second >= 0);

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
        hero_attribute_growth, hero_attributes_per_second,
        hero_critical_damage_bonus_pct, hero_attack_bonus_pct,
        hero_health_bonus_pct, hero_armor_bonus_pct, hero_damage_reduction_pct,
        tower_attack_bonus_pct, tower_attack_speed_bonus_pct,
        tower_attack_armor_reduction, tower_critical_chance_pct,
        tower_attack_interval, tower_final_damage_bonus_pct,
        tower_attack_per_second, wall_damage_block, wall_damage_reduction_pct,
        wall_armor_bonus_pct, wall_health_regen_per_second, wall_initial_health,
        wall_armor, wall_health_bonus_pct, wall_health_per_second,
        lumberjack_attack_growth, lumberjack_attack_speed_bonus_pct,
        online_seconds_total
    )
    select p_account_id, coalesce(x.initial_wood, 0), coalesce(x.initial_gold, 0),
        coalesce(x.wood_per_second, 0), coalesce(x.lumberjack_attack_efficiency, 0),
        coalesce(x.gold_per_second, 0), coalesce(x.gold_mine_efficiency_pct, 0),
        coalesce(x.initial_population_cap, 0), coalesce(x.starjoy_points, 0),
        coalesce(x.hero_initial_attack, 0), coalesce(x.hero_damage_attack_growth, 0),
        coalesce(x.hero_basic_attack_growth, 0), coalesce(x.hero_final_damage_bonus_pct, 0),
        coalesce(x.hero_attack_armor_reduction, 0), coalesce(x.hero_attribute_growth, 0),
        coalesce(x.hero_attributes_per_second, 0), coalesce(x.hero_critical_damage_bonus_pct, 0),
        coalesce(x.hero_attack_bonus_pct, 0), coalesce(x.hero_health_bonus_pct, 0),
        coalesce(x.hero_armor_bonus_pct, 0), coalesce(x.hero_damage_reduction_pct, 0),
        coalesce(x.tower_attack_bonus_pct, 0), coalesce(x.tower_attack_speed_bonus_pct, 0),
        coalesce(x.tower_attack_armor_reduction, 0), coalesce(x.tower_critical_chance_pct, 0),
        coalesce(x.tower_attack_interval, 0), coalesce(x.tower_final_damage_bonus_pct, 0),
        coalesce(x.tower_attack_per_second, 0), coalesce(x.wall_damage_block, 0),
        coalesce(x.wall_damage_reduction_pct, 0), coalesce(x.wall_armor_bonus_pct, 0),
        coalesce(x.wall_health_regen_per_second, 0), coalesce(x.wall_initial_health, 0),
        coalesce(x.wall_armor, 0), coalesce(x.wall_health_bonus_pct, 0),
        coalesce(x.wall_health_per_second, 0), coalesce(x.lumberjack_attack_growth, 0),
        coalesce(x.lumberjack_attack_speed_bonus_pct, 0), coalesce(x.online_seconds_total, 0)
    from jsonb_to_record(p_gameplay_stats) as x(
        initial_wood bigint, initial_gold bigint, wood_per_second numeric,
        lumberjack_attack_efficiency bigint, gold_per_second numeric,
        gold_mine_efficiency_pct numeric, initial_population_cap bigint,
        starjoy_points bigint, hero_initial_attack bigint,
        hero_damage_attack_growth numeric, hero_basic_attack_growth numeric,
        hero_final_damage_bonus_pct numeric, hero_attack_armor_reduction numeric,
        hero_attribute_growth numeric, hero_attributes_per_second numeric,
        hero_critical_damage_bonus_pct numeric, hero_attack_bonus_pct numeric,
        hero_health_bonus_pct numeric, hero_armor_bonus_pct numeric,
        hero_damage_reduction_pct numeric, tower_attack_bonus_pct numeric,
        tower_attack_speed_bonus_pct numeric, tower_attack_armor_reduction numeric,
        tower_critical_chance_pct numeric, tower_attack_interval numeric,
        tower_final_damage_bonus_pct numeric, tower_attack_per_second numeric,
        wall_damage_block numeric, wall_damage_reduction_pct numeric,
        wall_armor_bonus_pct numeric, wall_health_regen_per_second numeric,
        wall_initial_health bigint, wall_armor numeric, wall_health_bonus_pct numeric,
        wall_health_per_second numeric, lumberjack_attack_growth numeric,
        lumberjack_attack_speed_bonus_pct numeric, online_seconds_total bigint
    ) on conflict (player_id) do nothing;
    select * into v_stats from public.player_gameplay_stats where player_id = p_account_id;
    return to_jsonb(v_stats);
end;
$$;

revoke all on function public.ensure_player_gameplay_stats(text, jsonb) from public;
grant execute on function public.ensure_player_gameplay_stats(text, jsonb) to service_role;

commit;