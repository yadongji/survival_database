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

$rewardCsv = Read-Strict $addonRoot "data/csv/玩家档案系统/star_blessing_reward_definitions.csv"
$ruleCsv = Read-Strict $addonRoot "data/csv/玩家档案系统/fishing_system_rules.csv"
$baseMigration = Read-Strict $databaseRoot "supabase/migrations/202608170001_fishing_rewards.sql"
$grantMigration = Read-Strict $databaseRoot "supabase/migrations/202608210001_out_of_match_reward_grants.sql"
$cleanupMigration = Read-Strict $databaseRoot "supabase/migrations/202608230003_remove_legacy_fishing_persistence.sql"
$server = Read-Strict $databaseRoot "backend/fishing_api/server.py"
$application = Read-Strict $databaseRoot "backend/fishing_api/application.py"
$provider = Read-Strict $addonRoot "scripts/vscripts/systems/player_profile_providers/http_fishing_provider.lua"
$service = Read-Strict $addonRoot "scripts/vscripts/systems/fishing_reward_service.lua"
$profile = Read-Strict $addonRoot "scripts/vscripts/systems/player_profile_service.lua"
$router = Read-Strict $addonRoot "scripts/vscripts/ui/ui_request_router.lua"
$resources = Read-Strict $addonRoot "scripts/vscripts/systems/resource_system.lua"
$fixtureLua = Read-Strict $addonRoot "scripts/vscripts/tests/generated_fishing_reward_definitions.lua"
$providerTest = Read-Strict $addonRoot "tools/test_player_profile_provider_selection.lua"
$fixtureRewards = Read-Strict $databaseRoot "backend/tests/fixtures/star_blessing_reward_definitions.csv"
$starMigration = Read-Strict $databaseRoot "supabase/migrations/202608230001_star_blessing_reward_definitions.sql"
$grantIdMigration = Read-Strict $databaseRoot "supabase/migrations/202608230006_include_definition_version_in_online_grant_id.sql"
$finalMigration = Read-Strict $databaseRoot "supabase/migrations/202608230007_finalize_online_time_session.sql"
$fixtureRules = Read-Strict $databaseRoot "backend/tests/fixtures/fishing_system_rules.csv"
if ($ruleCsv -notmatch 'default_fishing,http://127\.0\.0\.1:8765,5,15,300,450,600,600,480,3,1,1') {
    throw "online timer rule mismatch"
foreach ($token in @(
    "checkpoint_online_time(text,text,text,integer,integer,integer,integer,boolean)",
    "p_final boolean", "session_id = p_session_id", "delete from public.online_time_sessions"
)) {
    if ($finalMigration -notmatch [regex]::Escape($token)) {
        throw "online final checkpoint migration contract missing: $token"
    }
}
}
if ($application -notmatch 'type\(final\) is not bool' -or
    $application -notmatch '"p_final": final') {
    throw "online final checkpoint API contract missing"
}
foreach ($token in @(
    "reward_grants", "player_effect_totals", "for update",
    "profile_revision = profile_revision + 1", "definition_hash",
    "reward_grants_immutable", "fishing_definitions_immutable",
    "revoke all on function public.fishing_profile_json(text) from public"
)) {
    if ($baseMigration -notmatch [regex]::Escape($token)) { throw "base migration contract missing: $token" }
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
foreach ($token in @(
    'register_server_convar\("survival_player_profile_provider", ""\)',
    'register_server_convar\("survival_fishing_api_token", ""\)',
    'register_server_convar\("survival_fishing_reward_fixture", ""\)',
    'local function ensure_provider\(\)',
    'local provider_ok, provider_error = ensure_provider\(\)',
    'provider_initialized provider_id='
)) {
    if ($profile -notmatch $token) {
        throw "HTTP profile provider startup contract missing: $token"
    }
}
foreach ($token in @(
    'late_override', 'restore_default', 'injected provider was not retained',
    'PLAYER_PROFILE_PROVIDER_SELECTION_LUA51_PASS'
)) {
    if ($providerTest -notmatch [regex]::Escape($token)) {
        throw "profile provider behavior coverage missing: $token"
    }
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
if ($starMigration -notmatch 'star_blessing_reward_definition_sets' -or
    $starMigration -notmatch 'star_blessing_reward_definitions' -or
    $starMigration -notmatch 'sync_star_blessing_reward_definitions' -or
    $starMigration -notmatch 'definition_version_hash_conflict' -or
    $starMigration -notmatch 'drop table public\.fishing_reward_definitions' -or
    $starMigration -notmatch 'legacy_definition_dependency_missing' -or
    $fixtureRewards -notmatch 'star_blessing_automation_9001,9001,测试全属性奖励,1,hero_all_attributes_flat,permanent,5,5' -or
    $fixtureRules -notmatch 'test_fishing,http://127\.0\.0\.1:8765,1,3,60,90,10,10,9001') {
    throw "isolated ten-second fishing fixtures missing"
}
foreach ($token in @(
    "checkpoint_online_time(text,text,text,integer,integer,integer,integer)",
    "online_grant_id_legacy_expression_missing",
    "md5(p_account_id || ':star:v' || p_definition_version::text || ':' || v_milestone::text)::uuid",
    "online_grant_id_definition_version_binding_failed",
    "pg_get_functiondef"
)) {
    if ($grantIdMigration -notmatch [regex]::Escape($token)) {
        throw "definition-version grant ID migration contract missing: $token"
    }
}
if ($grantIdMigration -match 'delete from public\.reward_grants|drop table public\.reward_grants|update public\.reward_grants') {
    throw "grant ID migration must preserve immutable reward history"
}
if ($fixtureLua -notmatch 'reward_id = "star_blessing_automation_9001"' -or
    $fixtureLua -notmatch 'definition_version = 9001' -or
    $fixtureLua -notmatch 'effect_key = "hero_all_attributes_flat"' -or
    $service -notmatch 'IsInToolsMode' -or
    $service -notmatch 'survival_fishing_reward_fixture' -or
    $service -notmatch 'fixture == "automation_9001"' -or
    $service -notmatch 'config/generated/fishing_reward_definitions' -or
    $application -notmatch 'sync_star_blessing_reward_definitions' -or
    $application -notmatch 'grant_id.*reward_id.*amount.*definition_version' -or
    $application -notmatch 'compact\.pop\(private_key' -or
    $application -match 'compact.*effect_key' -or
    $application -match 'compact.*definition_hash') {
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
if ($resources -notmatch 'accounts\[player_id\]' -or
    $resources -match 'accounts\[team\]' -or
    $resources -notmatch 'profile_not_loaded') {
    throw "private player resource ownership contract missing"
}
foreach ($token in @(
    'to_regprocedure',
    'drop function public\.heartbeat_fishing_session',
    'drop table if exists public\.fishing_idempotency',
    'drop table if exists public\.fishing_sessions',
    'drop table if exists public\.fishing_states',
    "'permanent_effects'", "'gameplay_stats'"
)) {
    if ($cleanupMigration -notmatch $token) { throw "legacy fishing cleanup missing: $token" }
}
if ($cleanupMigration -match 'online_time_sessions|online_time_idempotency|checkpoint_online_time|drop table public\.reward_grants|drop table public\.player_effect_totals') {
    throw "online time or star blessing persistence was included in legacy cleanup"
}
if ($server -match '/v1/fishing/heartbeat' -or
    $application -match 'heartbeat_fishing_session|def heartbeat' -or
    $provider -match 'fishing/heartbeat|function M\.heartbeat') {
    throw "legacy fishing heartbeat API still exposed"
}
Write-Output "FISHING_REWARD_CONTRACT_PASS"