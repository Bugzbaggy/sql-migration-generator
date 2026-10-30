<#
.SYNOPSIS
  End-to-end test: generate the sample branch's migrations, then deploy them with Flyway
  to SQL Server 2022 in Docker - an upgrade of a populated database and a fresh one - and
  run both scripts a second time to prove they are idempotent.

.DESCRIPTION
  Needs Docker and PowerShell 7. Pulls mcr.microsoft.com/mssql/server and flyway/flyway.
  Exits non-zero on the first failure; containers and the network are always removed.
#>
[CmdletBinding()]
param(
  [string]$SqlImage = 'mcr.microsoft.com/mssql/server:2022-CU14-ubuntu-22.04',
  [string]$FlywayImage = 'flyway/flyway:13.10.0',
  [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) "sqlmig-e2e-$PID")
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../SampleRepo.ps1')

$net = "sqlmig-e2e-$PID"; $db = "sqlmig-mssql-$PID"
# A throwaway container's password: random, never stored.
$pw = 'Sm1-' + [guid]::NewGuid().ToString('N')
$sqlcmd = '/opt/mssql-tools18/bin/sqlcmd'

function Step([string]$m) { Write-Host "`n=== $m" }
function Invoke-Native([string]$what) {
  # $args: the command line. Output is shown; a non-zero exit stops the test.
  & $args[0] @($args | Select-Object -Skip 1)
  if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}
function Invoke-Sql([string]$Database, [string]$Query) {
  Invoke-Native "sqlcmd on $Database" docker exec $db $sqlcmd -C -b -S localhost -U sa -P $pw -d $Database -Q $Query
}
function Invoke-SqlFile([string]$Database, [string]$Path) {
  $name = "/tmp/$([IO.Path]::GetFileName($Path))"
  Invoke-Native "docker cp $Path" docker cp $Path "${db}:$name"
  # -b: without it sqlcmd reports an error and still exits 0.
  Invoke-Native "sqlcmd -i $([IO.Path]::GetFileName($Path)) on $Database" docker exec $db $sqlcmd -C -b -S localhost -U sa -P $pw -d $Database -i $name
}
function Invoke-Flyway([string]$Database, [string]$Locations, [string]$Command = 'migrate') {
  # Quoted: PowerShell reads an unquoted -name:value token as parameter syntax and splits it.
  Invoke-Native "flyway $Command $Database" docker run --rm --network $net -v "${Locations}:/flyway/sql:ro" $FlywayImage `
    "-url=jdbc:sqlserver://${db}:1433;databaseName=$Database;encrypt=true;trustServerCertificate=true" `
    '-user=sa' "-password=$pw" '-locations=filesystem:/flyway/sql' '-validateMigrationNaming=true' $Command
}

try {
  Step 'Generate the migrations for feature/order-status'
  New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
  $repo = New-SqlMigSampleRepo (Join-Path $WorkDir 'repo')
  $resp = Join-Path $PSScriptRoot '../fixtures/order-status.response.xml'
  foreach ($a in @(@('context', '-Date', '2026-10-30'), @('apply', '-ResponseFile', $resp), @('build'), @('check'), @('project', '-Apply'), @('init', '-Check'))) {
    $r = Invoke-SqlMig $repo $a
    Write-Host $r.Output
    if ($r.Code -ne 0) { throw "sqlmig.ps1 $($a[0]) exited $($r.Code)" }
  }
  $mig = Join-Path $repo 'Migration'
  $baseline = Join-Path $WorkDir 'baseline'
  New-Item -ItemType Directory -Path $baseline -Force | Out-Null
  Copy-Item (Join-Path $mig '*2026-10-01.Sales.initial.sql') $baseline
  $v2 = Get-ChildItem $mig -Filter 'V1.00002__*.sql' | Select-Object -First 1
  $r2 = Get-ChildItem $mig -Filter 'R__2026-10-30.*.sql' | Select-Object -First 1
  if (-not $v2 -or -not $r2) { throw 'The branch scripts were not generated' }

  Step "Start SQL Server ($SqlImage); deploy with $FlywayImage"
  Invoke-Native 'docker network create' docker network create $net
  Invoke-Native 'docker run mssql' docker run -d --name $db --network $net -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$pw" -e MSSQL_PID=Developer $SqlImage
  $ready = $false
  for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
    Start-Sleep -Seconds 2
    docker exec $db $sqlcmd -C -b -S localhost -U sa -P $pw -Q 'SELECT 1' *> $null
    $ready = ($LASTEXITCODE -eq 0)
  }
  if (-not $ready) { docker logs $db; throw 'SQL Server did not start' }

  Step 'Provision the databases and the out-of-band deploy role'
  foreach ($d in 'SalesUpgrade', 'SalesFresh') {
    Invoke-Sql master "CREATE DATABASE [$d];"
    Invoke-Sql $d 'CREATE ROLE [role_app_ci] AUTHORIZATION [dbo];'
  }

  Step 'Upgrade: deploy main, add rows, then deploy the branch'
  Invoke-Flyway SalesUpgrade $baseline
  Invoke-SqlFile SalesUpgrade (Join-Path $PSScriptRoot 'seed-test-rows.sql')
  Invoke-Flyway SalesUpgrade $mig
  Invoke-Flyway SalesUpgrade $mig 'validate'

  Step 'Idempotency: run both branch scripts again'
  Invoke-SqlFile SalesUpgrade $v2.FullName
  Invoke-SqlFile SalesUpgrade $r2.FullName
  Invoke-Flyway SalesUpgrade $mig

  Step 'Fresh: deploy everything to an empty database'
  Invoke-Flyway SalesFresh $mig

  Step 'Assert the final state'
  Invoke-SqlFile SalesUpgrade (Join-Path $PSScriptRoot 'assert.sql')
  Invoke-Sql SalesFresh "IF OBJECT_ID('sales.Customer_GetLegacy') IS NOT NULL OR (SELECT COUNT(*) FROM ref.OrderStatus) <> 4 THROW 50001, 'fresh database is wrong', 1;"
  Write-Host "`nE2E PASSED"
} finally {
  docker rm -f $db *> $null
  docker network rm $net *> $null
  Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
}
