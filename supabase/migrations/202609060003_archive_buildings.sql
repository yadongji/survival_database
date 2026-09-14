-- Apply after 202609060002_all_archive.sql, before loading the new archive bundle.
begin;
alter table public.player_gameplay_stats
 add column if not exists wall_wave_boss_stun_seconds numeric not null default 0,
 add column if not exists hero_attack_pct_per_minute numeric not null default 0,
 add column if not exists tower_attack_pct_per_minute numeric not null default 0,
 add column if not exists hero_attributes_pct_per_minute numeric not null default 0;
-- Faith, daily acquisition and building levels are saved atomically in player_archive_state.archive.
commit;
