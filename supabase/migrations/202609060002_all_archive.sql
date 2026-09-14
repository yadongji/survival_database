-- Apply after existing migrations through 202608230007 and generated archive_stat_columns.sql.
begin;
-- Replace the old fixed-field initializer. New players use every CSV default;
-- existing players are never reset when configuration defaults change.
create or replace function public.ensure_player_gameplay_stats(p_account_id text,p_gameplay_stats jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare key text; columns_sql text:='player_id'; values_sql text:='$1'; result jsonb;
begin
 if p_account_id !~ '^[0-9a-f]{64}$' or jsonb_typeof(p_gameplay_stats)<>'object' then raise exception 'gameplay_defaults_invalid'; end if;
 insert into survival_players(account_id) values(p_account_id) on conflict do nothing;
 for key in select jsonb_object_keys(p_gameplay_stats) order by 1 loop
  if key !~ '^[a-z][a-z0-9_]*$' or key in ('player_id','created_at','updated_at') or not exists (
   select 1 from pg_attribute where attrelid='public.player_gameplay_stats'::regclass and attname=key and not attisdropped
  ) then raise exception 'gameplay_schema_mismatch'; end if;
  columns_sql:=columns_sql||format(',%I',key);
  values_sql:=values_sql||format(',x.%I',key);
 end loop;
 execute 'insert into public.player_gameplay_stats ('||columns_sql||') select '||values_sql||
  ' from jsonb_populate_record(null::public.player_gameplay_stats,$2) x on conflict(player_id) do nothing'
  using p_account_id,p_gameplay_stats;
 select to_jsonb(gs) into result from player_gameplay_stats gs where player_id=p_account_id;
 return result;
end; $$;
revoke all on function public.ensure_player_gameplay_stats(text,jsonb) from public,anon,authenticated;
grant execute on function public.ensure_player_gameplay_stats(text,jsonb) to service_role;

create table if not exists public.archive_config_sets (
 config_hash text primary key check(config_hash ~ '^[0-9a-f]{64}$'), config jsonb not null,
 created_at timestamptz not null default now()
);
create table if not exists public.player_archive_state (
 account_id text primary key references public.survival_players(account_id),
 archive jsonb not null default '{}'::jsonb, content_inventory jsonb not null default '{}'::jsonb
);
create table if not exists public.archive_entitlements (
 account_id text references public.survival_players(account_id), entitlement_id text not null,
 active boolean not null default false, starts_at timestamptz not null default now(), expires_at timestamptz,
 primary key(account_id,entitlement_id)
);
create table if not exists public.archive_operations (
 account_id text references public.survival_players(account_id), operation_id text not null,
 config_hash text not null references public.archive_config_sets(config_hash), fingerprint text not null,
 command jsonb not null, event_at timestamptz not null default now(), has_pass boolean not null,
 done boolean not null default false, error text, primary key(account_id,operation_id)
);
create table if not exists public.archive_online_outbox (
 account_id text references public.survival_players(account_id), request_id text not null,
 elapsed bigint not null, weighted bigint not null, created_at timestamptz not null default now(),
 primary key(account_id,request_id)
);
alter table public.archive_config_sets enable row level security;
alter table public.player_archive_state enable row level security;
alter table public.archive_entitlements enable row level security;
alter table public.archive_operations enable row level security;
alter table public.archive_online_outbox enable row level security;
revoke all on public.archive_config_sets, public.player_archive_state, public.archive_entitlements,
 public.archive_operations, public.archive_online_outbox from public, anon, authenticated;

create or replace function public.archive_sync_config(p_hash text,p_config jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
 if jsonb_typeof(p_config)<>'object' or octet_length(p_config::text)>4000000 then raise exception 'archive_config_invalid'; end if;
 insert into archive_config_sets(config_hash,config) values(p_hash,p_config) on conflict do nothing;
 select config into v from archive_config_sets where config_hash=p_hash;
 if v<>p_config then raise exception 'archive_config_immutable'; end if;
 return jsonb_build_object('ok',true);
end; $$;

-- Preserve the current profile implementation; append only the new private sections.
do $$
declare v text; marker text := '''save'', jsonb_build_object('; addition text := '';
begin
 select pg_get_functiondef('public.fishing_profile_json(text)'::regprocedure) into v;
 if position('''archive''' in v)=0 then
  if position(marker in v)=0 then raise exception 'archive_profile_layout_unexpected'; end if;
  addition := addition || $a$
   'archive', coalesce((select a.archive from public.player_archive_state a where a.account_id=p_account_id),'{}'::jsonb),
   'content_inventory', coalesce((select a.content_inventory from public.player_archive_state a where a.account_id=p_account_id),'{}'::jsonb),
  $a$;
 end if;
 if position('''fishing_inventory''' in v)=0 then
  addition := addition || $a$
   'fishing_inventory', coalesce((select jsonb_object_agg(x.reward_id,x.n) from (
    select reward_id,count(*) n from public.reward_grants where account_id=p_account_id
     and effect_scope='permanent' and reward_id ~ '^star_blessing_(00[1-9]|01[0-9]|02[0-6])$' group by reward_id
   )x),'{}'::jsonb),
  $a$;
 end if;
 v:=replace(v,marker,marker||addition);
 if position('public.archive_entitlements' in v)=0 then
  if position('''entitlements'', ''{}''::jsonb' in v)=0 then raise exception 'archive_entitlement_layout_unexpected'; end if;
  v:=replace(v,'''entitlements'', ''{}''::jsonb',$a$'entitlements', coalesce((
   select jsonb_object_agg(e.entitlement_id,jsonb_build_object('active',e.active and e.starts_at<=now(),
    'expires_at',case when e.expires_at is null then null else extract(epoch from e.expires_at)::bigint end))
    from public.archive_entitlements e where e.account_id=p_account_id),'{}'::jsonb)$a$);
 end if;
 execute v;
end; $$;

create or replace function public.archive_resume(p_account text,p_id text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare op archive_operations%rowtype;
begin
 select * into op from archive_operations where account_id=p_account and operation_id=p_id;
 if not found then return jsonb_build_object('ok',false,'terminal',true,'error','archive_operation_missing'); end if;
 return jsonb_build_object('ok',op.error is null,'terminal',op.done,'done',op.done,'error',op.error,
  'profile',fishing_profile_json(p_account),'command',op.command,'has_pass',op.has_pass,
  'config_hash',op.config_hash,
  'server_time',extract(epoch from clock_timestamp())::bigint);
end; $$;

create or replace function public.archive_prepare(p_account text,p_id text,p_hash text,p_fingerprint text,p_command jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare op archive_operations%rowtype; stamp timestamptz:=clock_timestamp(); pass boolean; c jsonb:=p_command;
begin
 -- Match legacy online checkpoint's lock order: gameplay stats first, player revision second.
 perform 1 from player_gameplay_stats where player_id=p_account for update;
 perform 1 from survival_players where account_id=p_account for update;
 if not found then raise exception 'archive_account_missing'; end if;
 select * into op from archive_operations where account_id=p_account and operation_id=p_id;
 if found then
  if op.fingerprint<>p_fingerprint or op.config_hash<>p_hash then
   return jsonb_build_object('ok',false,'terminal',true,'error','archive_id_conflict');
  end if;
  return archive_resume(p_account,p_id);
 end if;
 select exists(select 1 from archive_entitlements where account_id=p_account and entitlement_id='archive_pass'
  and active and starts_at<=stamp and (expires_at is null or expires_at>stamp)) into pass;
 c:=c||jsonb_build_object('today',floor((extract(epoch from stamp)+28800)/86400)::bigint,
  'day_key',floor((extract(epoch from stamp)+28800)/86400)::bigint::text);
 insert into archive_operations(account_id,operation_id,config_hash,fingerprint,command,event_at,has_pass)
 values(p_account,p_id,p_hash,p_fingerprint,c,stamp,pass);
 return archive_resume(p_account,p_id);
end; $$;

create or replace function public.archive_commit(p_account text,p_id text,p_revision bigint,p_archive jsonb,p_deltas jsonb,p_error text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare op archive_operations%rowtype; revision bigint; entry record; spec jsonb; previous numeric; next_value numeric;
begin
 perform 1 from player_gameplay_stats where player_id=p_account for update;
 select profile_revision into revision from survival_players where account_id=p_account for update;
 select * into op from archive_operations where account_id=p_account and operation_id=p_id for update;
 if not found then raise exception 'archive_operation_missing'; end if;
 if op.done then return archive_resume(p_account,p_id); end if;
 if revision<>p_revision then return jsonb_build_object('ok',false,'error','archive_revision_conflict'); end if;
 if p_error is null then
  if jsonb_typeof(p_archive)<>'object' or jsonb_typeof(p_deltas)<>'object' then raise exception 'archive_state_invalid'; end if;
  for entry in select * from jsonb_each_text(p_deltas) loop
   select entries.spec into spec from archive_config_sets c,
    jsonb_array_elements(c.config->'configs'->'player_gameplay_stats'->'rows') as entries(spec)
    where c.config_hash=op.config_hash and entries.spec->>'field_id'=entry.key;
   if spec is null or entry.key='online_seconds_total' then raise exception 'archive_stat_invalid'; end if;
   execute format('select %I from public.player_gameplay_stats where player_id=$1',entry.key) into previous using p_account;
   next_value:=previous+entry.value::numeric;
   if next_value::text in ('NaN','Infinity','-Infinity') or next_value<(spec->>'min_value')::numeric
     or next_value>(spec->>'max_value')::numeric
     or (spec->>'storage_type'='integer' and next_value<>trunc(next_value)) then raise exception 'archive_stat_bounds'; end if;
   execute format('update public.player_gameplay_stats set %I=$1,updated_at=now() where player_id=$2',entry.key) using next_value,p_account;
  end loop;
  insert into player_archive_state(account_id,archive) values(p_account,p_archive)
   on conflict(account_id) do update set archive=excluded.archive;
  update survival_players set profile_revision=profile_revision+1,updated_at=now() where account_id=p_account;
 end if;
 update archive_operations set done=true,error=p_error where account_id=p_account and operation_id=p_id;
 return archive_resume(p_account,p_id);
end; $$;

-- Consume authoritative elapsed seconds from the already-integrated online system.
-- This trigger and the original checkpoint commit in one DB transaction.
create or replace function public.archive_capture_online() returns trigger
language plpgsql security definer set search_path=public as $$
declare elapsed bigint:=greatest(0,coalesce((new.response->>'elapsed_seconds')::bigint,0)); extra bigint:=0;
 stamp timestamptz:=clock_timestamp(); e archive_entitlements%rowtype;
begin
 if elapsed=0 then return new; end if;
 select * into e from archive_entitlements where account_id=new.account_id and entitlement_id='archive_pass';
 if found and e.active then
  extra:=greatest(0,floor(extract(epoch from (least(stamp,coalesce(e.expires_at,stamp))-
    greatest(stamp-elapsed*interval '1 second',e.starts_at)))))::bigint;
 end if;
 insert into archive_online_outbox(account_id,request_id,elapsed,weighted,created_at)
 values(new.account_id,new.request_id,elapsed,elapsed+least(elapsed,extra),stamp) on conflict do nothing;
 return new;
end; $$;
drop trigger if exists archive_capture_online on public.online_time_idempotency;
create trigger archive_capture_online after insert on public.online_time_idempotency
 for each row execute function public.archive_capture_online();

create or replace function public.archive_online_pending(p_account text,p_hash text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare row archive_online_outbox%rowtype; result jsonb:='[]'::jsonb; identifier text;
begin
 for row in select x.* from archive_online_outbox x left join archive_operations o
  on o.account_id=x.account_id and o.operation_id='online:'||x.request_id
  where x.account_id=p_account and not coalesce(o.done,false) order by x.created_at limit 64 loop
  identifier:='online:'||row.request_id;
  insert into archive_operations(account_id,operation_id,config_hash,fingerprint,command,event_at,has_pass)
   values(p_account,identifier,p_hash,identifier,jsonb_build_object('id',identifier,'kind','online_checkpoint',
    'session',identifier,'actual_seconds',row.elapsed,'map_seconds',row.weighted),row.created_at,false)
   on conflict do nothing;
  result:=result||jsonb_build_array(jsonb_build_object('id',identifier));
 end loop;
 return result;
end; $$;

create or replace function public.archive_pending(p_account text) returns jsonb
language sql security definer set search_path=public as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',operation_id)),'[]'::jsonb) from (
  select operation_id from archive_operations where account_id=p_account and not done order by event_at limit 64
 ) x;
$$;

revoke all on function public.archive_pending(text),public.archive_sync_config(text,jsonb),public.archive_resume(text,text),
 public.archive_prepare(text,text,text,text,jsonb),public.archive_commit(text,text,bigint,jsonb,jsonb,text),
 public.archive_online_pending(text,text),public.archive_capture_online() from public,anon,authenticated;
grant execute on function public.archive_pending(text),public.archive_sync_config(text,jsonb),public.archive_resume(text,text),
 public.archive_prepare(text,text,text,text,jsonb),public.archive_commit(text,text,bigint,jsonb,jsonb,text),
 public.archive_online_pending(text,text) to service_role;
commit;
