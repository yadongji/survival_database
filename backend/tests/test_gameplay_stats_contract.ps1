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
$csv = Import-Csv -LiteralPath $csvPath -Encoding UTF8 | Where-Object { $_.field_id -notlike '#*' }
$migration = Read-Strict $migrationPath
if ($csv.Count -ne 36) { throw "GAMEPLAY_STATS_COUNT_INVALID_$($csv.Count)" }
if (($csv.field_id | Select-Object -Unique).Count -ne 36) { throw 'GAMEPLAY_STATS_ID_DUPLICATE' }
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
$online = $csv | Where-Object { $_.field_id -eq 'online_seconds_total' }
if ($null -eq $online -or $online.storage_type -ne 'integer' -or
    $online.default_value -ne '0' -or $online.min_value -ne '0') {
    throw 'ONLINE_SECONDS_CSV_CONTRACT_INVALID'
}
foreach ($token in @(
    'online_seconds_total bigint not null default 0',
    'online_seconds_total = online_seconds_total + floor(v_elapsed)',
    'v_previous_session_id = p_session_id',
    'v_previous_session_id <> p_session_id',
    'p_heartbeat_lease_seconds',
    'select response into v_response from public.fishing_idempotency',
    'if v_response is not null then return v_response; end if;',
    'v_profile_changed boolean := false',
    'if v_profile_changed then'
)) {
    if ($migration -notmatch [regex]::Escape($token)) {
        throw "ONLINE_SECONDS_MIGRATION_TOKEN_MISSING_$token"
    }
}
$idempotencyIndex = $migration.IndexOf(
    'select response into v_response from public.fishing_idempotency'
)
$onlineUpdateIndex = $migration.IndexOf(
    'online_seconds_total = online_seconds_total + floor(v_elapsed)'
)
if ($idempotencyIndex -lt 0 -or $onlineUpdateIndex -lt 0 -or
    $idempotencyIndex -ge $onlineUpdateIndex) {
    throw 'ONLINE_SECONDS_IDEMPOTENCY_ORDER_INVALID'
}
if ($migration -notmatch 'v_previous_session_id = p_session_id[\s\S]{0,180}between 0 and p_heartbeat_lease_seconds[\s\S]{0,120}v_elapsed := extract') {
    throw 'ONLINE_SECONDS_ADJACENT_SESSION_LEASE_GUARD_INVALID'
}
Write-Output 'GAMEPLAY_STATS_CONTRACT_PASS'