[CmdletBinding()]
param(
    [switch]$Automation9001
)

$ErrorActionPreference = "Stop"
$databaseRoot = $PSScriptRoot
$envPath = Join-Path $databaseRoot ".env"

function Import-DotEnv([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing $path. Create it from .env.example and provide Supabase credentials."
    }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid .env entry. Expected NAME=value."
        }
        [Environment]::SetEnvironmentVariable($parts[0], $parts[1], "Process")
    }
}

function Protect-SecretFile([string]$path) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $existing = Get-Acl -LiteralPath $path
    $allowed = @($identity, "NT AUTHORITY\SYSTEM")
    $unexpected = @($existing.Access | Where-Object {
        $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $_.IsInherited -or
        $_.IdentityReference.Value -notin $allowed
    })
    $present = @($existing.Access | ForEach-Object {
        $_.IdentityReference.Value
    } | Select-Object -Unique)
    if ($unexpected.Count -eq 0 -and
        @($allowed | Where-Object { $_ -notin $present }).Count -eq 0) {
        return
    }
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($principal in @($identity, "NT AUTHORITY\SYSTEM")) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $principal,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $path -AclObject $acl
}

Import-DotEnv $envPath
Protect-SecretFile $envPath

foreach ($name in @(
    "FISHING_API_TOKEN", "FISHING_ACCOUNT_ID_PEPPER", "SUPABASE_URL",
    "SURVIVAL_ADDON_ROOT"
)) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match 'replace-with|your-project') {
        throw "$name is missing or still contains an example value."
    }
}
if ([string]::IsNullOrWhiteSpace($env:SUPABASE_SECRET_KEY) -and
    [string]::IsNullOrWhiteSpace($env:SUPABASE_SERVICE_ROLE_KEY)) {
    throw "SUPABASE_SECRET_KEY or SUPABASE_SERVICE_ROLE_KEY is required."
}
$supabaseKey = if ($env:SUPABASE_SECRET_KEY) {
    $env:SUPABASE_SECRET_KEY
} else {
    $env:SUPABASE_SERVICE_ROLE_KEY
}
if ($supabaseKey -match 'replace-with') {
    throw "The Supabase key still contains an example value."
}
if (-not (Test-Path -LiteralPath $env:SURVIVAL_ADDON_ROOT -PathType Container)) {
    throw "SURVIVAL_ADDON_ROOT does not exist."
}

if ($Automation9001) {
    $env:FISHING_REWARD_CSV = "backend/tests/fixtures/fishing_reward_definitions.csv"
    $env:FISHING_RULE_CSV = "backend/tests/fixtures/fishing_system_rules.csv"
}

$python = if ($env:FISHING_PYTHON) {
    $env:FISHING_PYTHON
} else {
    (Get-Command python -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Python executable not found: $python"
}

& $python (Join-Path $databaseRoot "backend\run_fishing_api.py")
exit $LASTEXITCODE
