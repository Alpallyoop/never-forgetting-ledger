param()

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Split-Path -Parent $PSScriptRoot)
$Principal = "single-tenant/local/authority/nfl"
$KeyId = "dev-1"
$PubKeyPath = Join-Path $RepoRoot "proofs\keys\nfl-local_ed25519.pub"

if (-not (Test-Path -LiteralPath $PubKeyPath)) { throw ("Missing pubkey: " + $PubKeyPath) }

$pub = (Get-Content -LiteralPath $PubKeyPath -TotalCount 1).Trim()
"PRINCIPAL: " + $Principal
"KEY_ID:    " + $KeyId
"PUBKEY:    " + $pub
