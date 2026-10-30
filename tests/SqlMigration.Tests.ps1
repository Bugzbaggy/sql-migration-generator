#Requires -Version 7.2
# Pester 5+. Run from the repository root:  Invoke-Pester ./tests

BeforeAll {
  . (Join-Path $PSScriptRoot 'SampleRepo.ps1')
  . (Join-Path $PSScriptRoot '../skills/sql-migration-generator/scripts/SqlMigration.Core.ps1')
  $script:Response = Join-Path $PSScriptRoot 'fixtures/order-status.response.xml'
  $script:Expected = Join-Path $PSScriptRoot '../examples/expected'
  $script:VName = 'V1.00002__2026-10-30.Sales.feature.order-status.sql'
  $script:RName = 'R__2026-10-30.Sales.feature.order-status.sql'
  function Get-Context([string]$Repo) { Get-Content (Join-Path $Repo '.git/sqlmig/context.json') -Raw | ConvertFrom-Json -AsHashtable }
  function Set-File([string]$Repo, [string]$Rel, [string]$Text) {
    $p = Join-Path $Repo $Rel
    New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($p, $Text)
  }
}

Describe 'The sample branch, end to end' {
  BeforeAll {
    $script:repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'flow')
    $script:ctxRun = Invoke-SqlMig $repo @('context', '-Date', '2026-10-30')
    $script:ctx = Get-Context $repo
    $script:applyRun = Invoke-SqlMig $repo @('apply', '-ResponseFile', $Response)
    $script:buildRun = Invoke-SqlMig $repo @('build')
    $script:checkRun = Invoke-SqlMig $repo @('check')
  }

  It 'context succeeds and names the next version after main''s V1.00001' {
    $ctxRun.Code | Should -Be 0
    $ctx.nextVersion | Should -Be 'V1.00002'
    $ctx.versionFile | Should -Be "Migration/$VName"
    $ctx.repeatableFile | Should -Be "Migration/$RName"
    $ctx.branchSlug | Should -Be 'feature.order-status'
  }

  It 'context classifies every changed file' {
    $kinds = @{}; foreach ($s in $ctx.summary) { $kinds[$s.File] = "$($s.Status) $($s.Kind)" }
    $kinds['Sales/ref/Tables/OrderStatus.sql'] | Should -Be 'A structure'
    $kinds['Sales/sales/Tables/Order.sql'] | Should -Be 'M structure'
    $kinds['Sales/sales/Stored Procedures/Customer_GetLegacy.sql'] | Should -Be 'D repeatable'
    $kinds['Sales/Scripts/ReferenceData/ref.OrderStatus.sql'] | Should -Be 'A other'
    $kinds['Sales/Security/audit.sql'] | Should -Be 'A security'
    $ctx.versionCandidates | Should -Contain 'Sales/ref/Synonyms/Country.sql'
    $ctx.versionCandidates | Should -Not -Contain 'Sales/sales/Views/vwOrderStatus.sql'
  }

  It 'context gives a deleted file its content from the merge base' {
    $ctx.changes['Sales/sales/Stored Procedures/Customer_GetLegacy.sql'].Content | Should -Match 'CREATE PROCEDURE \[sales\]\.\[Customer_GetLegacy\]'
  }

  It 'apply writes the versioned script under the context''s name' {
    $applyRun.Code | Should -Be 0
    Join-Path $repo "Migration/$VName" | Should -Exist
  }

  It 'build produces exactly the expected versioned script' {
    $buildRun.Code | Should -Be 0
    Get-Normalized (Join-Path $repo "Migration/$VName") | Should -Be (Get-Normalized (Join-Path $Expected $VName))
  }

  It 'build moves the stray object-level grant out of the versioned script' {
    $buildRun.Output | Should -Match 'Moved 1 object-level grant'
    Get-Content (Join-Path $repo "Migration/$VName") -Raw | Should -Not -Match 'ON OBJECT::'
  }

  It 'build maps the $(Catalog) SQLCMD variable to its database name' {
    $v = Get-Content (Join-Path $repo "Migration/$VName") -Raw
    $v | Should -Match 'FOR AppCatalog\.\[geo\]\.\[Country\]'
    $v | Should -Not -Match '\$\('
  }

  It 'build produces exactly the expected repeatable script' {
    Get-Normalized (Join-Path $repo "Migration/$RName") | Should -Be (Get-Normalized (Join-Path $Expected $RName))
  }

  It 'the repeatable script drops first, then function, view, procedure, then table grants and triggers' {
    $r = Get-Content (Join-Path $repo "Migration/$RName") -Raw
    $order = 'DROP PROCEDURE IF EXISTS \[sales\]\.\[Customer_GetLegacy\]', 'CREATE OR ALTER FUNCTION \[sales\]\.\[fnOrderTotal\]',
      'CREATE OR ALTER VIEW \[sales\]\.\[vwOrderStatus\]', 'CREATE OR ALTER PROCEDURE \[sales\]\.\[Order_GetByStatus\]',
      'ON OBJECT::\[ref\]\.\[OrderStatus\]', 'CREATE OR ALTER TRIGGER \[sales\]\.\[trg_Order_StatusAudit\]'
    $at = @($order | ForEach-Object { [regex]::Match($r, $_).Index })
    $at | Should -Not -Contain 0 -Because 'every part is present (none at offset 0 except possibly the header)'
    ($at | Sort-Object) -join ',' | Should -Be ($at -join ',')
  }

  It 'build writes CRLF line endings (the configured default)' {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $repo "Migration/$RName"))
    $lf = @($bytes | Where-Object { $_ -eq 10 }).Count
    $cr = @($bytes | Where-Object { $_ -eq 13 }).Count
    $cr | Should -Be $lf
  }

  It 'check passes and warns that the online index follows an ALTER of the same table' {
    $checkRun.Code | Should -Be 0
    $checkRun.Output | Should -Match 'Object-order check passed'
    $checkRun.Output | Should -Match 'ONLINE index on sales\.order follows an ALTER TABLE'
  }

  It 'prompt fills every placeholder and leaves out the interactive procedure' {
    $p = Invoke-SqlMig $repo @('prompt', '-OutFile', (Join-Path $TestDrive 'prompt.md'))
    $p.Code | Should -Be 0
    $text = Get-Content (Join-Path $TestDrive 'prompt.md') -Raw
    $text | Should -Not -Match '\{\{[A-Z_]+\}\}'
    $text | Should -Not -Match 'interactive:begin'
    $text | Should -Match 'Sales/ref/Tables/OrderStatus.sql'
    $text | Should -Match '\| `\$\(Catalog\)` \| `AppCatalog` \|'
  }
}

Describe 'check rejects scripts that would fail to deploy' {
  BeforeAll {
    $script:repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'bad')
    (Invoke-SqlMig $repo @('context', '-Date', '2026-10-30')).Code | Should -Be 0
    $script:good = Get-Content $Response -Raw
  }

  It 'fails when the foreign key comes before its lookup table is seeded (error 547)' {
    $resp = $good
    $fk = [regex]::Match($resp, '(?s)IF NOT EXISTS \(SELECT 1 FROM sys\.foreign_keys.*?\nGO\n').Value
    $seed = [regex]::Match($resp, '(?s)-- Seed ref\.OrderStatus.*?\nGO\n').Value
    $fk | Should -Not -BeNullOrEmpty; $seed | Should -Not -BeNullOrEmpty
    $resp = $resp.Replace($fk, '').Replace($seed, $fk + "`n" + $seed)
    Set-File $repo 'bad.xml' $resp
    (Invoke-SqlMig $repo @('apply', '-ResponseFile', (Join-Path $repo 'bad.xml'))).Code | Should -Be 0
    (Invoke-SqlMig $repo @('build')).Code | Should -Be 0
    $r = Invoke-SqlMig $repo @('check')
    $r.Code | Should -Be 1
    $r.Output | Should -Match 'the foreign key on sales\.order to ref\.orderstatus comes before ref\.orderstatus is seeded'
    $r.Output | Should -Match 'error 547'
  }

  It 'fails when a column is used in the batch that adds it' {
    $resp = $good -replace '(?s)(ALTER TABLE \[sales\]\.\[Order\] ADD \[StatusId\][^\n]*\n)', "`$1`tUPDATE [sales].[Order] SET [StatusId] = 2 WHERE [Total] > 100;`n"
    Set-File $repo 'bad2.xml' $resp
    (Invoke-SqlMig $repo @('apply', '-ResponseFile', (Join-Path $repo 'bad2.xml'))).Code | Should -Be 0
    (Invoke-SqlMig $repo @('build')).Code | Should -Be 0
    $r = Invoke-SqlMig $repo @('check')
    $r.Code | Should -Be 1
    $r.Output | Should -Match 'uses column sales\.order\.statusid before it is added'
  }

  It 'fails when the versioned script uses a view this branch adds in the repeatable one' {
    $resp = $good.Replace('</CONTENT>', "SELECT TOP (1) [OrderId] INTO #probe FROM [sales].[vwOrderStatus];`nGO`n</CONTENT>")
    Set-File $repo 'bad3.xml' $resp
    (Invoke-SqlMig $repo @('apply', '-ResponseFile', (Join-Path $repo 'bad3.xml'))).Code | Should -Be 0
    (Invoke-SqlMig $repo @('build')).Code | Should -Be 0
    $r = Invoke-SqlMig $repo @('check')
    $r.Code | Should -Be 1
    $r.Output | Should -Match 'sales\.vworderstatus, which this branch adds in the repeatable migration'
  }

  It 'fails when a SQLCMD variable has no mapping' {
    $cfgPath = Join-Path $repo 'migration.config.json'
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json -AsHashtable
    $cfg.sqlcmdVariables = @{}
    [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 5))
    (Invoke-SqlMig $repo @('apply', '-ResponseFile', $Response)).Code | Should -Be 0
    $b = Invoke-SqlMig $repo @('build')
    $b.Code | Should -Be 1
    $b.Output | Should -Match '\$\(Catalog\) has no entry in sqlcmdVariables'
    $c = Invoke-SqlMig $repo @('check')
    $c.Code | Should -Be 1
    $c.Output | Should -Match 'SQLCMD variable \$\(Catalog\) is still in the script'
  }
}

Describe 'Regenerating on the same branch' {
  BeforeAll { $script:repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'regen') }

  It 'reuses the version held by the branch''s own earlier script, and -RemoveExisting deletes it' {
    Set-File $repo 'Migration/V1.00002__2026-10-29.Sales.feature.order-status.sql' "SELECT 1;`r`nGO`r`n"
    git -C $repo add -A; git -C $repo commit -q -m 'earlier generation'
    $r = Invoke-SqlMig $repo @('context', '-Date', '2026-10-30', '-RemoveExisting')
    $r.Code | Should -Be 0
    (Get-Context $repo).nextVersion | Should -Be 'V1.00002'
    $r.Output | Should -Match 'Removed old script Migration/V1\.00002__2026-10-29'
    Join-Path $repo 'Migration/V1.00002__2026-10-29.Sales.feature.order-status.sql' | Should -Not -Exist
  }

  It 'keeps an earlier script with uncommitted edits unless -Force' {
    git -C $repo checkout -q -- Migration
    Set-File $repo 'Migration/V1.00002__2026-10-29.Sales.feature.order-status.sql' "SELECT 2; -- hand edit`r`nGO`r`n"
    $r = Invoke-SqlMig $repo @('context', '-Date', '2026-10-30', '-RemoveExisting')
    $r.Output | Should -Match 'Kept Migration/V1\.00002__2026-10-29.*uncommitted edits'
    Join-Path $repo 'Migration/V1.00002__2026-10-29.Sales.feature.order-status.sql' | Should -Exist
    (Invoke-SqlMig $repo @('context', '-Date', '2026-10-30', '-RemoveExisting', '-Force')).Code | Should -Be 0
    Join-Path $repo 'Migration/V1.00002__2026-10-29.Sales.feature.order-status.sql' | Should -Not -Exist
  }

  It 'skips another branch''s scripts when numbering' {
    Set-File $repo 'Migration/V1.00002__2026-10-28.Sales.feature.other.sql' "SELECT 1;`r`nGO`r`n"
    (Invoke-SqlMig $repo @('context', '-Date', '2026-10-30')).Code | Should -Be 0
    (Get-Context $repo).nextVersion | Should -Be 'V1.00003'
  }
}

Describe 'Repeatable objects that move or vanish' {
  It 'builds a renamed (moved) procedure into the repeatable script' {
    $repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'rename') -NoBranch
    git -C $repo checkout -q -b feature/move
    New-Item -ItemType Directory -Path (Join-Path $repo 'Sales/sales/Stored Procedures/Customers') -Force | Out-Null
    git -C $repo mv 'Sales/sales/Stored Procedures/Customer_Get.sql' 'Sales/sales/Stored Procedures/Customers/Customer_Get.sql'
    git -C $repo commit -q -m move
    (Invoke-SqlMig $repo @('context', '-Date', '2026-10-30')).Code | Should -Be 0
    $s = @((Get-Context $repo).summary)
    $s[0].Status | Should -Match '^R'
    (Invoke-SqlMig $repo @('build')).Code | Should -Be 0
    Get-Content (Join-Path $repo 'Migration/R__2026-10-30.Sales.feature.move.sql') -Raw | Should -Match 'CREATE OR ALTER PROCEDURE \[sales\]\.\[Customer_Get\]'
  }

  It 'drops a trigger that a table file no longer defines' {
    $repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'trigger')
    git -C $repo checkout -q -b feature/no-trigger
    $order = Join-Path $repo 'Sales/sales/Tables/Order.sql'
    $text = [IO.File]::ReadAllText($order)
    [IO.File]::WriteAllText($order, $text.Substring(0, $text.IndexOf('CREATE TRIGGER')))
    git -C $repo commit -qam 'drop trigger'
    (Invoke-SqlMig $repo @('context', '-Date', '2026-10-30', '-Base', 'feature/order-status')).Code | Should -Be 0
    $b = Invoke-SqlMig $repo @('build')
    $b.Code | Should -Be 0
    Get-Content (Join-Path $repo 'Migration/R__2026-10-30.Sales.feature.no-trigger.sql') -Raw | Should -Match 'DROP TRIGGER IF EXISTS \[sales\]\.\[trg_Order_StatusAudit\]'
  }

  It 'treats an uncommitted change as part of the branch, and -CommittedOnly ignores it' {
    $repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'wip') -NoBranch
    git -C $repo checkout -q -b feature/wip
    $p = Join-Path $repo 'Sales/sales/Views/vwCustomerOrders.sql'
    [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace 'c\.\[Name\] AS \[CustomerName\]', 'c.[Name] AS [CustomerName], c.[Email]'))
    (Invoke-SqlMig $repo @('context')).Code | Should -Be 0
    @((Get-Context $repo).summary).Count | Should -Be 1
    (Invoke-SqlMig $repo @('context', '-CommittedOnly')).Code | Should -Be 0
    @((Get-Context $repo).summary).Count | Should -Be 0
  }

  It 'marks a whitespace-only change so it is skipped' {
    $repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'ws') -NoBranch
    git -C $repo checkout -q -b feature/ws
    $p = Join-Path $repo 'Sales/sales/Tables/Customer.sql'
    [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) + "`n`n"))
    (Invoke-SqlMig $repo @('context')).Code | Should -Be 0
    @((Get-Context $repo).summary)[0].WhitespaceOnly | Should -BeTrue
    (Get-Context $repo).versionCandidates.Count | Should -Be 0
  }
}

Describe 'init and project' {
  It 'init derives the configuration from the .sqlproj' {
    $repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'init') -NoConfig
    $r = Invoke-SqlMig $repo @('init')
    $r.Code | Should -Be 0
    $c = Get-Content (Join-Path $repo 'migration.config.json') -Raw | ConvertFrom-Json -AsHashtable
    $c.database | Should -Be 'Sales'
    $c.sourceRoot | Should -Be 'Sales'
    $c.project | Should -Be 'Sales/Sales.sqlproj'
    $c.baseBranch | Should -Be 'main'
    $c.ciRole | Should -Be 'role_app_ci'
    $c.ciRoleFile | Should -Be 'Sales/Security/role_app_ci.sql'
    $c.sqlcmdVariables.Catalog | Should -Be 'AppCatalog'
    (Invoke-SqlMig $repo @('init')).Code | Should -Be 1 -Because 'it never overwrites without -Force'
  }

  It 'init -Check fails for a variable the config does not map' {
    $repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'drift')
    Set-File $repo 'Sales/ref/Synonyms/Rate.sql' "CREATE SYNONYM [ref].[Rate] FOR [`$(Pricing)].[fx].[Rate];`r`nGO`r`n"
    $r = Invoke-SqlMig $repo @('init', '-Check')
    $r.Code | Should -Be 1
    $r.Output | Should -Match '\$\(Pricing\) is used in source but has no entry in sqlcmdVariables'
  }

  It 'project -Apply adds the deploy-role grants and project items, and a second run changes nothing' {
    $repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'project')
    (Invoke-SqlMig $repo @('context', '-Date', '2026-10-30')).Code | Should -Be 0
    $dry = Invoke-SqlMig $repo @('project')
    $dry.Output | Should -Match 'would add ALTER, SELECT, INSERT, UPDATE, DELETE, EXECUTE, REFERENCES on audit'
    git -C $repo diff --quiet; $LASTEXITCODE | Should -Be 0 -Because 'a dry run writes nothing'
    (Invoke-SqlMig $repo @('project', '-Apply')).Code | Should -Be 0
    $role = Get-Content (Join-Path $repo 'Sales/Security/role_app_ci.sql') -Raw
    ([regex]::Matches($role, 'ON SCHEMA::\[audit\] TO \[role_app_ci\]')).Count | Should -Be 7
    [xml]$proj = Get-Content (Join-Path $repo 'Sales/Sales.sqlproj') -Raw
    $inc = @($proj.Project.ItemGroup | ForEach-Object { $_.ChildNodes } | Where-Object { $_.Include } | ForEach-Object { "$($_.LocalName) $($_.Include)" })
    $inc | Should -Contain 'Build ref\Tables\OrderStatus.sql'
    $inc | Should -Contain 'None Scripts\ReferenceData\ref.OrderStatus.sql'
    $inc | Should -Contain 'Folder audit\Tables\'
    $inc | Should -Not -Contain 'Build sales\Stored Procedures\Customer_GetLegacy.sql'
    $again = Invoke-SqlMig $repo @('project', '-Apply')
    $again.Output | Should -Match 'every schema folder is granted'
    $again.Output | Should -Match 'already lists every file'
    (Invoke-SqlMig $repo @('init', '-Check')).Output | Should -Match 'matches the project'
  }

  It 'project leaves an SDK-style project alone' {
    $repo = New-SqlMigSampleRepo (Join-Path $TestDrive 'sdk')
    Set-File $repo 'Sales/Sales.sqlproj' "<Project Sdk=`"Microsoft.Build.Sql/1.0.0`">`n  <PropertyGroup><Name>Sales</Name></PropertyGroup>`n</Project>`n"
    git -C $repo commit -qam sdk
    (Invoke-SqlMig $repo @('context', '-Date', '2026-10-30')).Code | Should -Be 0
    (Invoke-SqlMig $repo @('project', '-Apply')).Output | Should -Match 'SDK-style project'
  }
}

Describe 'Unit: helpers' {
  BeforeAll {
    $script:cfg = @{ database = 'Sales'; sqlcmdVariables = [ordered]@{ Catalog = 'AppCatalog'; Same = 'Same'; Odd = 'My-Db' } }
  }

  It 'maps bracketed and bare SQLCMD variables, case-insensitively' {
    $r = Convert-SqlMigVariables 'FOR [$(catalog)].geo.Country; SELECT * FROM $(Same).dbo.T' $cfg
    $r.Text | Should -Be 'FOR AppCatalog.geo.Country; SELECT * FROM Same.dbo.T'
    $r.Unmapped.Count | Should -Be 0
  }

  It 'keeps brackets for a database name that is not a regular identifier' {
    (Convert-SqlMigVariables 'FOR [$(Odd)].a.b' $cfg).Text | Should -Be 'FOR [My-Db].a.b'
  }

  It 'replaces a bare variable name left in a synonym FOR clause' {
    (Convert-SqlMigVariables 'CREATE SYNONYM x.y FOR [Catalog].geo.Country' $cfg).Text | Should -Be 'CREATE SYNONYM x.y FOR AppCatalog.geo.Country'
  }

  It 'reports a variable it cannot map and leaves it in place' {
    $r = Convert-SqlMigVariables 'FOR [$(Nope)].a.b' $cfg
    $r.Text | Should -Be 'FOR [$(Nope)].a.b'
    $r.Unmapped -join ',' | Should -Be 'Nope'
  }

  It 'removes only object-level grant batches from a versioned script' {
    $n = 0
    $out = Remove-SqlMigObjectGrants "CREATE TABLE a.b (x INT NOT NULL);`nGO`nGRANT SELECT ON OBJECT::a.b TO r;`nGO`nGRANT ALTER ON SCHEMA::a TO ci;`nGO" ([ref]$n)
    $n | Should -Be 1
    $out | Should -Match 'ON SCHEMA::a'
    $out | Should -Not -Match 'ON OBJECT::'
    $n2 = 0
    Remove-SqlMigObjectGrants "-- only a grant`nGRANT EXECUTE ON OBJECT::a.p TO r;`nGO" ([ref]$n2) | Should -BeNullOrEmpty
  }

  It 'numbers versions with rollover and five-digit minors' {
    $d = Join-Path $TestDrive 'ver'
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    (Get-SqlMigNextVersion $d '.x.y.sql').Version | Should -Be 'V1.00001'
    Set-Content (Join-Path $d 'V1.99999__2026-01-01.Sales.a.sql') ''
    (Get-SqlMigNextVersion $d '.Sales.b.sql').Version | Should -Be 'V2.00001'
    (Get-SqlMigNextVersion $d '.Sales.a.sql').Version | Should -Be 'V1.00001' -Because 'the branch''s own script is being replaced'
  }

  It 'reads a model response and refuses a truncated one' {
    $r = Read-SqlMigResponse (Get-Content $Response -Raw)
    $r.Version | Should -Match '^-- Migration generated for branch'
    $r.VersionFileName | Should -Be $VName
    { Read-SqlMigResponse '<MIGRATION_RESPONSE><VERSION_MIGRATION><CONTENT>CREATE TABLE' } | Should -Throw '*truncated*'
  }

  It 'matches MSBuild wildcards the way MSBuild does' {
    Test-SqlMigMsbuildWildcard 'sales\**\*.sql' 'sales\Tables\Order.sql' | Should -BeTrue
    Test-SqlMigMsbuildWildcard 'sales\*.sql' 'sales\Tables\Order.sql' | Should -BeFalse
    Test-SqlMigMsbuildWildcard '**\*.sql' 'a.sql' | Should -BeTrue
  }
}
