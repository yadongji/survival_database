begin;

create table if not exists public.out_of_match_reward_idempotency (
    grant_id uuid primary key references public.reward_grants(grant_id) on delete restrict,
    account_id text not null references public.survival_players(account_id) on delete cascade,
    request_fingerprint text not null check (request_fingerprint ~ '^[0-9a-f]{64}$'),
    response jsonb not null,
    created_at timestamptz not null default now()
);
revoke all on table public.out_of_match_reward_idempotency from anon, authenticated;

create or replace function public.grant_out_of_match_reward(
    p_account_id text,
    p_grant_id uuid,
    p_reward_id text,
    p_definition_version integer,
    p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_reward public.fishing_reward_definitions%rowtype;
    v_existing public.reward_grants%rowtype;
    v_definition_hash text;
    v_applied numeric;
    v_response jsonb;
    v_saved_response jsonb;
    v_request_fingerprint text;
    v_saved_fingerprint text;
begin
    if p_account_id !~ '^[0-9a-f]{64}$'
        or p_reward_id !~ '^[A-Za-z0-9_.:-]{1,128}$'
        or p_definition_version < 1
        or p_amount is null or p_amount <> trunc(p_amount) then
        raise exception 'out_of_match_grant_payload_invalid';
    end if;

    v_request_fingerprint := encode(digest(
        p_account_id || E'\n' || p_reward_id || E'\n'
            || p_definition_version::text || E'\n' || p_amount::text,
        'sha256'
    ), 'hex');
    perform pg_advisory_xact_lock(hashtextextended(p_grant_id::text, 0));
    select request_fingerprint, response
    into v_saved_fingerprint, v_saved_response
    from public.out_of_match_reward_idempotency
    where grant_id = p_grant_id;
    if found then
        if v_saved_fingerprint <> v_request_fingerprint then
            raise exception 'grant_id_conflict';
        end if;
        return v_saved_response;
    end if;
    if exists (select 1 from public.reward_grants where grant_id = p_grant_id) then
        raise exception 'grant_id_conflict';
    end if;

    select d.* into v_reward
    from public.fishing_reward_definitions d
    where d.definition_version = p_definition_version
      and d.reward_id = p_reward_id
    for share;
    if not found or v_reward.effect_scope <> 'permanent' then
        raise exception 'out_of_match_reward_invalid';
    end if;
    if p_amount < v_reward.value_min or p_amount > v_reward.value_max then
        raise exception 'out_of_match_reward_amount_invalid';
    end if;
    select definition_hash into v_definition_hash
    from public.fishing_reward_definition_sets
    where definition_version = p_definition_version;
    if v_definition_hash is null then raise exception 'definition_version_missing'; end if;

    perform 1 from public.survival_players
    where account_id = p_account_id for update;
    if not found then raise exception 'player_missing'; end if;
    perform 1 from public.player_gameplay_stats
    where player_id = p_account_id for update;
    if not found then raise exception 'gameplay_stats_missing'; end if;

    if v_reward.effect_key = 'initial_wood' then
        update public.player_gameplay_stats set
            initial_wood = case when v_reward.stacking_rule = 'max'
                then greatest(initial_wood, p_amount::bigint)
                else initial_wood + p_amount::bigint end,
            updated_at = now()
        where player_id = p_account_id returning initial_wood into v_applied;
    elsif v_reward.effect_key = 'initial_gold' then
        update public.player_gameplay_stats set
            initial_gold = case when v_reward.stacking_rule = 'max'
                then greatest(initial_gold, p_amount::bigint)
                else initial_gold + p_amount::bigint end,
            updated_at = now()
        where player_id = p_account_id returning initial_gold into v_applied;
    elsif v_reward.effect_key = 'initial_population_cap' then
        update public.player_gameplay_stats set
            initial_population_cap = case when v_reward.stacking_rule = 'max'
                then greatest(initial_population_cap, p_amount::bigint)
                else initial_population_cap + p_amount::bigint end,
            updated_at = now()
        where player_id = p_account_id returning initial_population_cap into v_applied;
    elsif v_reward.effect_key = 'wood_per_second' then
        update public.player_gameplay_stats set
            wood_per_second = case when v_reward.stacking_rule = 'max'
                then greatest(wood_per_second, p_amount)
                else wood_per_second + p_amount end,
            updated_at = now()
        where player_id = p_account_id returning wood_per_second into v_applied;
    elsif v_reward.effect_key = 'gold_per_second' then
        update public.player_gameplay_stats set
            gold_per_second = case when v_reward.stacking_rule = 'max'
                then greatest(gold_per_second, p_amount)
                else gold_per_second + p_amount end,
            updated_at = now()
        where player_id = p_account_id returning gold_per_second into v_applied;
    else
        insert into public.player_effect_totals(account_id, effect_key, total_value)
        values (p_account_id, v_reward.effect_key, p_amount)
        on conflict (account_id, effect_key) do update set
            total_value = case when v_reward.stacking_rule = 'max'
                then greatest(public.player_effect_totals.total_value, excluded.total_value)
                else public.player_effect_totals.total_value + excluded.total_value end,
            updated_at = now()
        returning total_value into v_applied;
    end if;

    if v_reward.cap_value is not null and v_reward.cap_value > 0 then
        if v_reward.effect_key = 'initial_wood' then
            update public.player_gameplay_stats set initial_wood = least(initial_wood, v_reward.cap_value::bigint)
            where player_id = p_account_id returning initial_wood into v_applied;
        elsif v_reward.effect_key = 'initial_gold' then
            update public.player_gameplay_stats set initial_gold = least(initial_gold, v_reward.cap_value::bigint)
            where player_id = p_account_id returning initial_gold into v_applied;
        elsif v_reward.effect_key = 'initial_population_cap' then
            update public.player_gameplay_stats set initial_population_cap = least(initial_population_cap, v_reward.cap_value::bigint)
            where player_id = p_account_id returning initial_population_cap into v_applied;
        elsif v_reward.effect_key = 'wood_per_second' then
            update public.player_gameplay_stats set wood_per_second = least(wood_per_second, v_reward.cap_value)
            where player_id = p_account_id returning wood_per_second into v_applied;
        elsif v_reward.effect_key = 'gold_per_second' then
            update public.player_gameplay_stats set gold_per_second = least(gold_per_second, v_reward.cap_value)
            where player_id = p_account_id returning gold_per_second into v_applied;
        else
            update public.player_effect_totals set total_value = least(total_value, v_reward.cap_value)
            where account_id = p_account_id and effect_key = v_reward.effect_key
            returning total_value into v_applied;
        end if;
    end if;

    insert into public.reward_grants(
        grant_id, account_id, reward_id, effect_key, effect_scope, amount,
        definition_version, definition_hash
    ) values (
        p_grant_id, p_account_id, p_reward_id, v_reward.effect_key,
        v_reward.effect_scope, p_amount, p_definition_version, v_definition_hash
    ) returning * into v_existing;

    update public.survival_players set profile_revision = profile_revision + 1,
        updated_at = now() where account_id = p_account_id;

    v_response := jsonb_build_object(
        'ok', true,
        'duplicate', false,
        'applied_total', v_applied,
        'grant', jsonb_build_object(
            'grant_id', v_existing.grant_id,
            'reward_id', v_existing.reward_id,
            'effect_key', v_existing.effect_key,
            'effect_scope', v_existing.effect_scope,
            'amount', v_existing.amount,
            'definition_version', v_existing.definition_version,
            'definition_hash', v_existing.definition_hash,
            'granted_at', v_existing.granted_at
        ),
        'profile', public.fishing_profile_json(p_account_id)
    );
    insert into public.out_of_match_reward_idempotency(
        grant_id, account_id, request_fingerprint, response
    ) values (p_grant_id, p_account_id, v_request_fingerprint, v_response);
    return v_response;
end;
$$;

revoke all on function public.grant_out_of_match_reward(text, uuid, text, integer, numeric) from public;
grant execute on function public.grant_out_of_match_reward(text, uuid, text, integer, numeric) to service_role;

commit;