-- Remove the retired +1/s default once; retain every earned increment above it.
begin;
create table if not exists public.survival_data_migrations (
 migration_id text primary key, applied_at timestamptz not null default now()
);
revoke all on public.survival_data_migrations from public,anon,authenticated;
alter table public.player_gameplay_stats alter column wood_per_second set default 0;
do $$
begin
 insert into public.survival_data_migrations(migration_id)
 values('20260914_remove_default_wood_income') on conflict do nothing;
 if not found then return; end if;
 -- Same lock order as gameplay writes: stats first, player revision second.
 with changed as (
  update public.player_gameplay_stats
  set wood_per_second=greatest(0,wood_per_second-1),updated_at=now()
  where wood_per_second>0 returning player_id
 )
 update public.survival_players p set profile_revision=profile_revision+1,updated_at=now()
 from changed c where p.account_id=c.player_id;
end; $$;
commit;
