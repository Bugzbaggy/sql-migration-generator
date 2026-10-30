# Builds a throwaway git repository from examples/: main holds examples/sales-db, and the
# branch feature/order-status applies examples/sales-db.branch (files to add or replace)
# and deletes what examples/sales-db.branch/deleted.txt lists.

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:Examples = Join-Path $script:RepoRoot 'examples'
$script:SqlMig = Join-Path $script:RepoRoot 'skills/sql-migration-generator/scripts/sqlmig.ps1'

function Invoke-Git { git @args 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed" } }

function Copy-Tree([string]$From, [string]$To) {
  $base = (Resolve-Path -LiteralPath $From).ProviderPath.TrimEnd('\', '/')
  foreach ($f in Get-ChildItem -LiteralPath $base -Recurse -File -Force) {
    $rel = $f.FullName.Substring($base.Length + 1)
    $dest = Join-Path $To $rel
    $dir = Split-Path $dest -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
  }
}

function New-SqlMigSampleRepo([string]$Path, [switch]$NoBranch, [switch]$NoConfig) {
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  Copy-Tree (Join-Path $script:Examples 'sales-db') $Path
  if ($NoConfig) { Remove-Item -LiteralPath (Join-Path $Path 'migration.config.json') }
  Push-Location -LiteralPath $Path
  try {
    Invoke-Git init -q -b main
    Invoke-Git config user.name 'Test Author'
    Invoke-Git config user.email 'test@example.com'
    Invoke-Git config core.autocrlf false
    Invoke-Git config commit.gpgsign false
    Invoke-Git add -A
    Invoke-Git commit -q -m 'main'
    if (-not $NoBranch) {
      Invoke-Git checkout -q -b feature/order-status
      $branch = Join-Path $script:Examples 'sales-db.branch'
      foreach ($top in Get-ChildItem -LiteralPath $branch -Directory) { Copy-Tree $top.FullName (Join-Path $Path $top.Name) }
      foreach ($d in Get-Content -LiteralPath (Join-Path $branch 'deleted.txt')) { if ($d.Trim()) { Remove-Item -LiteralPath (Join-Path $Path $d.Trim()) } }
      Invoke-Git add -A
      Invoke-Git commit -q -m 'order status'
    }
  } finally { Pop-Location }
  (Resolve-Path -LiteralPath $Path).ProviderPath
}

# Runs sqlmig.ps1 in $Repo; returns @{ Code; Output }.
function Invoke-SqlMig([string]$Repo, [string[]]$Arguments) {
  Push-Location -LiteralPath $Repo
  try {
    $out = & pwsh -NoProfile -NonInteractive -File $script:SqlMig @Arguments 2>&1 | Out-String
    @{ Code = $LASTEXITCODE; Output = $out }
  } finally { Pop-Location }
}

function Get-Normalized([string]$Path) { ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n").TrimEnd() }
