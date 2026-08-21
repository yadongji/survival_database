[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$envPath = Join-Path $PSScriptRoot ".env"
if (Test-Path -LiteralPath $envPath) {
    throw "$envPath already exists. Refusing to overwrite server secrets."
}

function New-RandomHex([int]$byteCount) {
    $bytes = [byte[]]::new($byteCount)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

$content = @(
    "FISHING_API_HOST=127.0.0.1"
    "FISHING_API_PORT=8765"
    "FISHING_API_TOKEN=$(New-RandomHex 32)"
    "FISHING_ACCOUNT_ID_PEPPER=$(New-RandomHex 32)"
    "SUPABASE_URL="
    "SUPABASE_SECRET_KEY="
    "SURVIVAL_ADDON_ROOT=D:\steam\steamapps\common\dota 2 beta\game\dota_addons\survival"
    "FISHING_REQUEST_TIMEOUT_SECONDS=8"
    "FISHING_PYTHON=C:\Users\a\.workbuddy\binaries\python\versions\3.14.3\python.exe"
) -join "`n"
[System.IO.File]::WriteAllText(
    $envPath,
    $content + "`n",
    [System.Text.UTF8Encoding]::new($false)
)

$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
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
Set-Acl -LiteralPath $envPath -AclObject $acl

Write-Output "FISHING_ENV_INITIALIZED"
Write-Output "Fill SUPABASE_URL and SUPABASE_SECRET_KEY in $envPath before startup."
