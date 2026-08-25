begin;

create or replace function public.checkpoint_online_time(
    p_account_id text,
    p_session_id text,
    p_request_id text,
    p_lease_seconds integer,
    p_definition_version integer,
    p_interval_min_seconds integer,
    p_interval_max_seconds integer,
    p_final boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_response jsonb;
begin
    if p_final is null then
        raise exception 'online_time_payload_invalid';
    end if;
    v_response := public.checkpoint_online_time(
        p_account_id,
        p_session_id,
        p_request_id,
        p_lease_seconds,
        p_definition_version,
        p_interval_min_seconds,
        p_interval_max_seconds
    );
    if p_final then
        delete from public.online_time_sessions
        where account_id = p_account_id and session_id = p_session_id;
    end if;
    return v_response;
end;
$$;

revoke all on function public.checkpoint_online_time(
    text, text, text, integer, integer, integer, integer, boolean
) from public, anon, authenticated;
grant execute on function public.checkpoint_online_time(
    text, text, text, integer, integer, integer, integer, boolean
) to service_role;

commit;