$ErrorActionPreference = 'Stop'
$databaseRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$addonRoot = $env:SURVIVAL_ADDON_ROOT
if ([string]::IsNullOrWhiteSpace($addonRoot) -or -not (Test-Path -LiteralPath $addonRoot)) {
    throw 'SURVIVAL_ADDON_ROOT must point to the Survival addon'
}
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
function Read-Strict([string]$path) {
    return [System.IO.File]::ReadAllText($path, $utf8)
}

$csvPath = Join-Path $addonRoot 'data/csv/玩家档案系统/player_gameplay_stats.csv'
$migrationPath = Join-Path $databaseRoot 'supabase/migrations/202608200001_player_gameplay_stats.sql'
$onlineMigrationPath = Join-Path $databaseRoot 'supabase/migrations/202608210002_online_time_checkpoints.sql'
$intervalMigrationPath = Join-Path $databaseRoot 'supabase/migrations/202608230005_fix_gameplay_stats_attack_interval.sql'
$csv = Import-Csv -LiteralPath $csvPath -Encoding UTF8 | Where-Object { $_.field_id -notlike '#*' }
$migration = Read-Strict $migrationPath
$onlineMigration = Read-Strict $onlineMigrationPath
$intervalMigration = Read-Strict $intervalMigrationPath
if ($csv.Count -ne 38) { throw "GAMEPLAY_STATS_COUNT_INVALID_$($csv.Count)" }
if (($csv.field_id | Select-Object -Unique).Count -ne 38) { throw 'GAMEPLAY_STATS_ID_DUPLICATE' }
foreach ($row in $csv) {
    if ($row.default_value -eq '' -or $row.min_value -eq '') { throw "GAMEPLAY_STATS_DEFAULT_OR_MIN_MISSING_$($row.field_id)" }
}
foreach ($token in @(
    'create table if not exists public.player_gameplay_stats',
    'player_id text primary key',
    'ensure_player_gameplay_stats',
    'jsonb_to_record',
    "fishing_profile_json",
    "'gameplay_stats'",
    "revoke all on table public.player_gameplay_stats"
)) {
    if ($migration -notmatch [regex]::Escape($token)) { throw "GAMEPLAY_STATS_MIGRATION_TOKEN_MISSING_$token" }
}
if ($migration -match 'player_id bigint|player_id integer') { throw 'PLAYER_ID_MUST_NOT_BE_SLOT_NUMBER' }
$interval = $csv | Where-Object { $_.field_id -eq 'tower_attack_interval' }
if ($null -eq $interval -or $interval.default_value -ne '1.7' -or $interval.min_value -ne '0.01') {
    throw 'TOWER_ATTACK_INTERVAL_CSV_CONTRACT_INVALID'
}
foreach ($token in @(
    'create or replace function public.ensure_player_gameplay_stats',
    'case when x.tower_attack_interval is null or x.tower_attack_interval <= 0',
    'then 1.7 else x.tower_attack_interval end',
    'on conflict (account_id) do nothing',
    'on conflict (player_id) do nothing'
)) {
    if ($intervalMigration -notmatch [regex]::Escape($token)) {
        throw "ATTACK_INTERVAL_MIGRATION_TOKEN_MISSING_$token"
    }
}
$online = $csv | Where-Object { $_.field_id -eq 'online_seconds_total' }
if ($null -eq $online -or $online.storage_type -ne 'integer' -or
    $online.default_value -ne '0' -or $online.min_value -ne '0') {
    throw 'ONLINE_SECONDS_CSV_CONTRACT_INVALID'
}
foreach ($token in @(
    'create table if not exists public.online_time_sessions',
    'create table if not exists public.online_time_idempotency',
    'create or replace function public.checkpoint_online_time',
    'online_seconds_total + v_elapsed',
    'v_previous_session = p_session_id',
    'select response into v_response from public.online_time_idempotency',
    'if v_response is not null then return v_response; end if;'
)) {
    if ($onlineMigration -notmatch [regex]::Escape($token)) {
        throw "ONLINE_SECONDS_MIGRATION_TOKEN_MISSING_$token"
    }
}
$idempotencyIndex = $onlineMigration.IndexOf(
    'select response into v_response from public.online_time_idempotency'
)
$onlineUpdateIndex = $onlineMigration.IndexOf('online_seconds_total + v_elapsed')
if ($idempotencyIndex -lt 0 -or $onlineUpdateIndex -lt 0 -or
    $idempotencyIndex -ge $onlineUpdateIndex) {
    throw 'ONLINE_SECONDS_IDEMPOTENCY_ORDER_INVALID'
}
Write-Output 'GAMEPLAY_STATS_CONTRACT_PASS'