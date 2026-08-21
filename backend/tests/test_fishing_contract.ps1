$ErrorActionPreference = "Stop"
$databaseRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$addonRoot = $env:SURVIVAL_ADDON_ROOT
if ([string]::IsNullOrWhiteSpace($addonRoot) -or
    -not (Test-Path -LiteralPath $addonRoot -PathType Container)) {
    throw "SURVIVAL_ADDON_ROOT must point to the Survival addon"
}
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Read-Strict([string]$root, [string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path)) { throw "missing: $relative" }
    return [System.IO.File]::ReadAllText($path, $utf8)
}

$rewardCsv = Read-Strict $addonRoot "data/csv/玩家档案系统/fishing_reward_definitions.csv"
$ruleCsv = Read-Strict $addonRoot "data/csv/玩家档案系统/fishing_system_rules.csv"
$baseMigration = Read-Strict $databaseRoot "supabase/migrations/202608170001_fishing_rewards.sql"
$grantMigration = Read-Strict $databaseRoot "supabase/migrations/202608210001_out_of_match_reward_grants.sql"
$server = Read-Strict $databaseRoot "backend/fishing_api/server.py"
$application = Read-Strict $databaseRoot "backend/fishing_api/application.py"
$provider = Read-Strict $addonRoot "scripts/vscripts/systems/player_profile_providers/http_fishing_provider.lua"
$service = Read-Strict $addonRoot "scripts/vscripts/systems/fishing_reward_service.lua"
$profile = Read-Strict $addonRoot "scripts/vscripts/systems/player_profile_service.lua"
$router = Read-Strict $addonRoot "scripts/vscripts/ui/ui_request_router.lua"
$resources = Read-Strict $addonRoot "scripts/vscripts/systems/resource_system.lua"
$luaTest = Read-Strict $addonRoot "scripts/vscripts/tests/test_fishing_reward_service.lua"
$notificationTest = Read-Strict $addonRoot "scripts/vscripts/tests/test_ui_notification_audience.lua"
$fixtureLua = Read-Strict $addonRoot "scripts/vscripts/tests/generated_fishing_reward_definitions.lua"
$fixtureRewards = Read-Strict $databaseRoot "backend/tests/fixtures/fishing_reward_definitions.csv"
$fixtureRules = Read-Strict $databaseRoot "backend/tests/fixtures/fishing_system_rules.csv"

$enabled = Import-Csv -LiteralPath (Join-Path $addonRoot "data/csv/玩家档案系统/fishing_reward_definitions.csv") |
    Where-Object { $_.reward_id -notlike "#*" -and $_.enabled -in @("1", "true") }
if ($enabled.Count -ne 0) { throw "unreviewed production rewards must remain disabled" }
foreach ($pending in @("pending_reward_body", "pending_lumberjack_speed_x4", "pending_lumberjack_speed_5pct")) {
    if ($rewardCsv -notmatch [regex]::Escape($pending)) { throw "pending definition missing: $pending" }
}
if ($ruleCsv -notmatch 'default_fishing,http://127\.0\.0\.1:8765,5,15,60,600,1,1,1') {
    throw "online timer rule mismatch"
}
foreach ($token in @(
    "reward_grants", "player_effect_totals", "fishing_idempotency",
    "heartbeat_fishing_session", "for update", "profile_revision = profile_revision + 1",
    "remaining_seconds", "last_heartbeat_at", "definition_hash",
    "unique index if not exists fishing_sessions_one_per_account_idx",
    "reward_grants_immutable", "fishing_definitions_immutable",
    "revoke all on function public.fishing_profile_json(text) from public"
)) {
    if ($baseMigration -notmatch [regex]::Escape($token)) { throw "base migration contract missing: $token" }
}
if ($baseMigration -notmatch "v_previous_session_id = p_session_id" -or
    $baseMigration -notmatch "v_previous_session_id <> p_session_id" -or
    $baseMigration -notmatch "fishing_session_active" -or
    $baseMigration -notmatch "p_heartbeat_lease_seconds") {
    throw "offline freeze/session lease contract missing"
}
foreach ($token in @(
    "create table if not exists public.out_of_match_reward_idempotency",
    "create or replace function public.grant_out_of_match_reward",
    "request_fingerprint", "response jsonb not null",
    "pg_advisory_xact_lock", "grant_id_conflict", "return v_saved_response",
    "for update", "player_gameplay_stats", "player_effect_totals",
    "cap_value", "profile_revision = profile_revision + 1",
    "grant execute on function public.grant_out_of_match_reward"
)) {
    if ($grantMigration -notmatch [regex]::Escape($token)) { throw "grant migration contract missing: $token" }
}
if ($server -notmatch '"/v1/rewards/grant"' -or
    $server -notmatch 'grant_out_of_match_reward' -or
    $application -notmatch 'def grant_out_of_match_reward' -or
    $application -notmatch '_ensure_gameplay_stats\(database_account_id\)' -or
    $application -notmatch '"grant_out_of_match_reward"') {
    throw "out-of-match grant API route or profile initialization missing"
}
if ($server -match "SUPABASE_SERVICE_ROLE_KEY.*response" -or
    $provider -match "SUPABASE|service_role|apikey") {
    throw "database credentials crossed the local API boundary"
}
if ($application -notmatch "hmac\.new" -or
    $application -notmatch "hashlib\.sha256" -or
    ([regex]::Matches($baseMigration, "\^\[0-9a-f\]\{64\}\$")).Count -lt 3 -or
    $baseMigration -match "p_account_id\s+!~\s+'\^\[0-9\]\+\$'") {
    throw "Steam Account ID HMAC pseudonymization contract missing"
}
if ($provider -notmatch "GetSteamAccountID" -or $provider -notmatch "Authorization") {
    throw "trusted Steam identity or local API authentication missing"
}
if ($profile -notmatch "survival_player_profile_provider") {
    throw "HTTP profile provider override missing"
}
if ($service -notmatch 'out_of_match_fishing_only' -or
    $service -notmatch 'function M\.connect' -or
    $service -notmatch 'function M\.disconnect' -or
    $service -match 'provider\.heartbeat' -or
    $service -match 'scheduler\.every' -or
    $service -match 'pending_request_id' -or
    $service -match 'RESOURCE_ADD_REQUEST') {
    throw "in-match fishing lifecycle still owns database or resource side effects"
}
if ($fixtureRewards -notmatch 'test_hero_attack_flat,9001,测试攻击奖励,1,hero_attack_flat,permanent,5,5' -or
    $fixtureRules -notmatch 'test_fishing,http://127\.0\.0\.1:8765,1,3,10,10,9001') {
    throw "isolated ten-second fishing fixtures missing"
}
if ($fixtureLua -notmatch 'definition_version = 9001' -or
    $fixtureLua -notmatch 'effect_key = "hero_attack_flat"' -or
    $service -notmatch 'IsInToolsMode' -or
    $service -notmatch 'survival_fishing_reward_fixture' -or
    $service -notmatch 'fixture == "automation_9001"' -or
    $service -notmatch 'config/generated/fishing_reward_definitions') {
    throw "Tools-only Lua fixture selection contract missing"
}
if ($service -notmatch 'reward_definition' -or
    $service -notmatch 'events\.FISHING_REWARD_GRANTED' -or
    $service -notmatch 'audience = "all"' -or
    $service -notmatch 'PlayerResource:GetPlayerName' -or
    $service -match 'message\s*=.*account_id' -or
    $service -match 'message\s*=.*definition_hash') {
    throw "safe fishing grant announcement contract missing"
}
if ($router -notmatch 'payload\.audience == "all"' -or
    $router -notmatch 'Send_ServerToAllClients' -or
    $router -notmatch 'send_to_player\("ui_notification", payload\.player_id') {
    throw "explicit broadcast or targeted notification compatibility missing"
}
if ($notificationTest -notmatch 'ordinary notification no longer targets one player' -or
    $notificationTest -notmatch 'explicit all-player notification was not safely broadcast' -or
    $notificationTest -notmatch 'account_id == nil') {
    throw "notification audience behavior coverage missing"
}
if ($resources -notmatch 'accounts\[player_id\]' -or
    $resources -match 'accounts\[team\]' -or
    $resources -notmatch 'profile_not_loaded') {
    throw "private player resource ownership contract missing"
}
foreach ($token in @(
    'local fishing = require\("systems/fishing_reward_service"\)',
    'out_of_match_fishing_only', 'scheduler\.task_count\(\)',
    'resource_requests == 0', 'grant_events == 1',
    'external permanent grant announcement mutated current match resources',
    'account_id == nil', 'invalid external grant was announced'
)) {
    if ($luaTest -notmatch $token) { throw "fishing behavior coverage missing: $token" }
}

Write-Output "FISHING_REWARD_CONTRACT_PASS"