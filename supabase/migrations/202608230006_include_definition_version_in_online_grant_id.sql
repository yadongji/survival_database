begin;

-- Reward definitions are immutable. Bind the definition version to the
-- deterministic milestone ID so a later definition set cannot reuse an old
-- grant ID with a different payload.
do $$
declare
    v_signature regprocedure :=
        'public.checkpoint_online_time(text,text,text,integer,integer,integer,integer)'::regprocedure;
    v_definition text;
begin
    v_definition := pg_get_functiondef(v_signature);
    if position($q$md5(p_account_id || ':star:' || v_milestone::text)::uuid$q$ in v_definition) = 0 then
        raise exception 'online_grant_id_legacy_expression_missing';
    end if;

    v_definition := replace(
        v_definition,
        $q$md5(p_account_id || ':star:' || v_milestone::text)::uuid$q$,
        $q$md5(p_account_id || ':star:v' || p_definition_version::text || ':' || v_milestone::text)::uuid$q$
    );
    execute v_definition;
end
$$;

do $$
declare
    v_definition text;
begin
    v_definition := pg_get_functiondef(
        'public.checkpoint_online_time(text,text,text,integer,integer,integer,integer)'::regprocedure
    );
    if position($q$':star:v' || p_definition_version::text$q$ in v_definition) = 0
        or position($q$':star:' || v_milestone::text$q$ in v_definition) <> 0 then
        raise exception 'online_grant_id_definition_version_binding_failed';
    end if;
end
$$;

commit;