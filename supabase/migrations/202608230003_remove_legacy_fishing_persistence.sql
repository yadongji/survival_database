begin;

-- The old in-match fishing timer is retired. Keep this migration independent
-- from the online-time checkpoint and permanent reward tables.
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

do $$
begin
    if to_regprocedure(
        'public.heartbeat_fishing_session(text,text,text,integer,integer,integer,integer)'
    ) is not null then
        execute 'revoke all on function public.heartbeat_fishing_session(text,text,text,integer,integer,integer,integer) from public, anon, authenticated, service_role';
        execute 'drop function public.heartbeat_fishing_session(text,text,text,integer,integer,integer,integer)';
    end if;
end;
$$;

do $$
begin
    if to_regclass('public.fishing_idempotency') is not null then
        execute 'revoke all on table public.fishing_idempotency from public, anon, authenticated, service_role';
    end if;
    if to_regclass('public.fishing_sessions') is not null then
        execute 'revoke all on table public.fishing_sessions from public, anon, authenticated, service_role';
    end if;
    if to_regclass('public.fishing_states') is not null then
        execute 'revoke all on table public.fishing_states from public, anon, authenticated, service_role';
    end if;
end;
$$;

drop table if exists public.fishing_idempotency;
drop table if exists public.fishing_sessions;
drop table if exists public.fishing_states;

commit;