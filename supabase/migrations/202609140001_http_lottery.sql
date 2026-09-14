begin;
alter table public.archive_operations add column if not exists response jsonb;
create or replace function public.archive_resume(p_account text,p_id text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare op archive_operations%rowtype;
begin
 select * into op from archive_operations where account_id=p_account and operation_id=p_id;
 if not found then return jsonb_build_object('ok',false,'terminal',true,'error','archive_operation_missing'); end if;
 return jsonb_build_object('ok',op.error is null,'terminal',op.done,'done',op.done,'error',op.error,
  'profile',fishing_profile_json(p_account),'command',op.command,'has_pass',op.has_pass,
  'config_hash',op.config_hash,'response',op.response,
  'server_time',extract(epoch from clock_timestamp())::bigint);
end; $$;
create or replace function public.archive_commit_lottery(p_account text,p_id text,p_revision bigint,
 p_archive jsonb,p_deltas jsonb,p_error text,p_inventory jsonb,p_response jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare op archive_operations%rowtype; result jsonb; entry record;
begin
 perform 1 from player_gameplay_stats where player_id=p_account for update;
 perform 1 from survival_players where account_id=p_account for update;
 select * into op from archive_operations where account_id=p_account and operation_id=p_id for update;
 if not found then raise exception 'archive_operation_missing'; end if;
 if op.done then return archive_resume(p_account,p_id); end if;
 if op.command->>'kind' not in ('lottery_draw','lottery_exchange','lottery_read') then raise exception 'lottery_command_invalid'; end if;
 if p_error is null then
  if jsonb_typeof(p_inventory)<>'object' or jsonb_typeof(p_response)<>'object' then raise exception 'lottery_payload_invalid'; end if;
  for entry in select * from jsonb_each_text(p_inventory) loop
   if entry.value is null or entry.value !~ '^[0-9]+$' or length(entry.value)>16 or entry.value::numeric>9007199254740991 then raise exception 'lottery_inventory_invalid'; end if;
  end loop;
 end if;
 result:=archive_commit(p_account,p_id,p_revision,p_archive,p_deltas,p_error);
 if result->>'error'='archive_revision_conflict' then return result; end if;
 if p_error is null then
  update player_archive_state set content_inventory=p_inventory where account_id=p_account;
  update archive_operations set response=p_response where account_id=p_account and operation_id=p_id;
 end if;
 return archive_resume(p_account,p_id);
end; $$;
revoke all on function public.archive_commit_lottery(text,text,bigint,jsonb,jsonb,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.archive_commit_lottery(text,text,bigint,jsonb,jsonb,text,jsonb,jsonb) to service_role;
commit;
