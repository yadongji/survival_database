# Survival Fishing Database Service

This repository owns the local Python API and Supabase migration for Survival's
persistent fishing rewards. Gameplay configuration remains authoritative in the
Dota addon CSV files. Do not copy production reward CSVs into this repository.

## Trust Boundary

`Dota server Lua -> 127.0.0.1 Python API -> HTTPS Supabase API`

- The Python API must remain bound to loopback. Do not expose port `8765`.
- Dota clients never receive Supabase credentials or the local API token.
- The backend stores an HMAC-SHA256 pseudonym of each Steam Account ID in
  Supabase. Keep `FISHING_ACCOUNT_ID_PEPPER` stable and backed up.
- `.env` is excluded from Git and the startup script restricts its Windows ACL
  to the current user and `SYSTEM`.

## Initial Setup

1. Create a Supabase project.
2. Run `supabase/migrations/202608170001_fishing_rewards.sql` in its SQL editor.
   Then run `supabase/migrations/202608200001_player_gameplay_stats.sql` to add
   the CSV-backed player gameplay fields used by profile responses. The second
   migration also adds the permanent `online_seconds_total` counter and updates
   the heartbeat RPC to count only valid adjacent heartbeats in one active lease.
3. Run `initialize_fishing_env.ps1`. It creates independent random API-token
   and account-ID pepper values without printing them, then restricts the file
   ACL. Fill the blank Supabase URL and key in the resulting `.env`.
4. Prefer a new `sb_secret_...` key in `SUPABASE_SECRET_KEY`. The legacy
   `SUPABASE_SERVICE_ROLE_KEY` variable remains supported.
5. Set the Dota server ConVar `survival_fishing_api_token` to the exact
   `FISHING_API_TOKEN` value. Never put the pepper or Supabase key in Dota.

The pepper defines player identity in the database. Changing it after live data
exists makes every player appear to be a new account unless data is migrated.

## Run

Production configuration:

```powershell
& 'D:\survival_database\start_fishing_api.ps1'
```

Ten-second Tools Mode fixture (`definition_version = 9001`, attack `+5`):

```powershell
& 'D:\survival_database\start_fishing_api.ps1' -Automation9001
```

For the fixture, also set the Dota server ConVar
`survival_fishing_reward_fixture automation_9001`. Never use that ConVar in a
production room.

## Test

Set `SURVIVAL_ADDON_ROOT`, then run:

```powershell
& 'C:\Users\a\.workbuddy\binaries\python\versions\3.14.3\python.exe' -m unittest discover -s backend/tests -v
& 'C:\Program Files\PowerShell\7\pwsh.exe' -File backend/tests/test_fishing_contract.ps1
```

These are local unit and static contract tests. They do not constitute a live
Supabase migration test or Dota Workshop Tools validation.
