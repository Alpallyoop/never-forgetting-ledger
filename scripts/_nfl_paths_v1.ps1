# _nfl_paths_v1.ps1 -- dot-source helper: location-independent path resolution (no hard-coded drives).
# Read-only. Returns $null when nothing valid is found so callers can fail closed.
function Resolve-NflCprRoot([string]$RepoRoot,[string]$Explicit){
  # An explicit root (parameter, then NFL_CPR_ROOT) is authoritative: if it is wrong the answer is
  # "not found", never a silent fallback to some other CPR checkout.
  $chosen = if(-not [string]::IsNullOrWhiteSpace($Explicit)){ $Explicit } elseif(-not [string]::IsNullOrWhiteSpace($env:NFL_CPR_ROOT)){ $env:NFL_CPR_ROOT } else { $null }
  if($null -ne $chosen){
    if(Test-Path -LiteralPath (Join-Path $chosen "scripts\verify_packet_v1.ps1") -PathType Leaf){ return (Resolve-Path -LiteralPath $chosen).Path }
    return $null
  }
  $cands = New-Object System.Collections.Generic.List[string]
  $parent = Split-Path -Parent $RepoRoot
  $grand  = if($parent){ Split-Path -Parent $parent } else { $null }
  foreach($base in @($parent,$grand)){
    if(-not $base){ continue }
    $cands.Add((Join-Path $base "cpr"))
    try { foreach($d in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction Stop)){ $cands.Add((Join-Path $d.FullName "cpr")) } } catch {}
  }
  foreach($c in $cands){
    if(Test-Path -LiteralPath (Join-Path $c "scripts\verify_packet_v1.ps1") -PathType Leaf){ return (Resolve-Path -LiteralPath $c).Path }
  }
  return $null
}
function Resolve-NflConstellationRoot([string]$RepoRoot,[string]$Explicit){
  $cands = New-Object System.Collections.Generic.List[string]
  if(-not [string]::IsNullOrWhiteSpace($Explicit)){ $cands.Add($Explicit) }
  # canonical per CLAUDE.md / project.contract.json: ../../Constellation-Network
  $cands.Add((Join-Path $RepoRoot "..\..\Constellation-Network"))
  foreach($c in $cands){ if(Test-Path -LiteralPath $c -PathType Container){ return (Resolve-Path -LiteralPath $c).Path } }
  return $null
}
