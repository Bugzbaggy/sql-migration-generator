# Everything sqlmig.ps1 does, as functions. Dot-source this file from the repository root
# of an SSDT database project; every git call and relative path assumes that location.

. (Join-Path $PSScriptRoot 'MigrationObjects.ps1')

$script:RepeatableFolderRx = '[/\\](Views|Stored Procedures?|Functions|Triggers)[/\\]'
$script:ObjectFolders = @('Tables', 'Views', 'Stored Procedures', 'Stored Procedure', 'Functions', 'Triggers', 'Synonyms', 'User Defined Types', 'Sequences')
$script:StructureFolders = @('Tables', 'Synonyms', 'User Defined Types', 'Sequences')

function Write-SqlMigNote([string]$Level, [string]$Message) {
  if ($Level -eq 'info') { Write-Host $Message; return }
  if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::${Level}::$Message" }
  else { Write-Host "$($Level.ToUpperInvariant()): $Message" }
}

# ---------------------------------------------------------------------------------------
# Configuration (migration.config.json at the repository root)
# ---------------------------------------------------------------------------------------

function Get-SqlMigDefaultConfig {
  [ordered]@{
    database        = $null
    project         = $null
    sourceRoot      = $null
    migrationDir    = 'Migration'
    baseBranch      = 'main'
    firstVersion    = 'V1.00001'
    ciRole          = $null
    ciRoleFile      = $null
    sqlcmdVariables = [ordered]@{}
    lineEndings     = 'crlf'
    excludeDirs     = @('bin', 'obj', 'Scripts', 'Security', 'Storage', 'Properties', 'external-refs', '.vs')
  }
}

function ConvertTo-SqlMigRelPath([string]$Path) {
  $p = ($Path -replace '\\', '/').Trim()
  while ($p.StartsWith('./')) { $p = $p.Substring(2) }
  $p = $p.TrimEnd('/')
  if (-not $p) { '.' } else { $p }
}

function Get-SqlMigConfig([string]$Path = 'migration.config.json') {
  if (-not (Test-Path -LiteralPath $Path)) { throw "No $Path in $((Get-Location).ProviderPath) - run: sqlmig.ps1 init" }
  try { $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
  catch { throw "$Path is not valid JSON: $($_.Exception.Message)" }
  $cfg = Get-SqlMigDefaultConfig
  foreach ($k in $raw.Keys) {
    if (-not $cfg.Contains($k)) { Write-SqlMigNote warning "$Path has an unknown key '$k' - ignored" ; continue }
    $cfg[$k] = $raw[$k]
  }
  foreach ($req in 'database', 'sourceRoot') { if (-not $cfg[$req]) { throw "$Path must set '$req'" } }
  if ($cfg.firstVersion -notmatch '^V(\d+)\.(\d+)$') { throw "firstVersion '$($cfg.firstVersion)' must look like V1.00001" }
  if ($cfg.lineEndings -notin @('crlf', 'lf')) { throw "lineEndings must be 'crlf' or 'lf'" }
  $cfg.sourceRoot = ConvertTo-SqlMigRelPath $cfg.sourceRoot
  $cfg.migrationDir = ConvertTo-SqlMigRelPath $cfg.migrationDir
  if ($cfg.ciRoleFile) { $cfg.ciRoleFile = ConvertTo-SqlMigRelPath $cfg.ciRoleFile }
  if ($cfg.project) { $cfg.project = ConvertTo-SqlMigRelPath $cfg.project }
  if ($null -eq $cfg.sqlcmdVariables) { $cfg.sqlcmdVariables = [ordered]@{} }
  # git pathspec for the project's source files: '*' crosses '/' in a plain pathspec, so
  # 'Src/*.sql' is every .sql file below Src. Generated scripts and build output never count.
  $spec = if ($cfg.sourceRoot -eq '.') { '*.sql' } else { "$($cfg.sourceRoot)/*.sql" }
  $cfg.Pathspec = @($spec, ":(exclude)$($cfg.migrationDir)/*", ':(exclude,glob)**/bin/**', ':(exclude,glob)**/obj/**')
  $null = $cfg.firstVersion -match '^V(\d+)\.(\d+)$'
  $cfg.MinorDigits = $matches[2].Length
  $cfg
}

# Every .sql file under the source root, minus build output and the migration folder.
function Get-SqlMigSourceFiles($Cfg) {
  $root = (Get-Location).ProviderPath.TrimEnd('\', '/')
  $src = if ($Cfg.sourceRoot -eq '.') { $root } else { Join-Path $root $Cfg.sourceRoot }
  if (-not (Test-Path -LiteralPath $src)) { return }
  $mig = (Join-Path $root $Cfg.migrationDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -Filter *.sql -File -ErrorAction SilentlyContinue) {
    if ($f.FullName.StartsWith($mig, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
    if ($rel -match '(^|/)(bin|obj|\.git)/') { continue }
    [pscustomobject]@{ FullName = $f.FullName; Rel = $rel }
  }
}

# The schema folders: directories directly under the source root that hold object folders.
function Get-SqlMigSchemaDirs($Cfg) {
  $src = if ($Cfg.sourceRoot -eq '.') { '.' } else { $Cfg.sourceRoot }
  @(Get-ChildItem -LiteralPath $src -Directory -ErrorAction SilentlyContinue |
    Where-Object { $Cfg.excludeDirs -notcontains $_.Name -and $_.Name -ne (Split-Path $Cfg.migrationDir -Leaf) } |
    Where-Object { $d = $_.FullName; @($script:ObjectFolders | Where-Object { Test-Path -LiteralPath (Join-Path $d $_) }).Count -gt 0 } |
    Select-Object -ExpandProperty Name | Sort-Object)
}

# ---------------------------------------------------------------------------------------
# init: build migration.config.json from the .sqlproj
# ---------------------------------------------------------------------------------------

function Find-SqlMigCiRole($Cfg) {
  # The CI/CD deploy role is the role that is granted ALTER on the most schemas.
  $best = $null
  foreach ($f in @(Get-SqlMigSourceFiles $Cfg | Where-Object { $_.Rel -match '(^|/)Security/' })) {
    $code = Get-CodeView ([IO.File]::ReadAllText($f.FullName))
    $counts = @{}
    foreach ($m in [regex]::Matches($code, "(?i)\bGRANT\s+ALTER\s+ON\s+SCHEMA\s*::\s*$SqlPart\s+TO\s+(?<r>$SqlPart)")) {
      $r = @(Split-SqlName $m.Groups['r'].Value)[0]
      $counts[$r] = 1 + [int]$counts[$r]
    }
    foreach ($r in $counts.Keys) {
      if (-not $best -or $counts[$r] -gt $best.Count) { $best = @{ Role = $r; File = $f.Rel; Count = $counts[$r] } }
    }
  }
  $best
}

function Get-SqlMigProjectVariables([string]$ProjectFile) {
  $vars = [ordered]@{}
  if (-not $ProjectFile -or -not (Test-Path -LiteralPath $ProjectFile)) { return $vars }
  [xml]$proj = Get-Content -LiteralPath $ProjectFile -Raw
  foreach ($n in $proj.SelectNodes("//*[local-name()='SqlCmdVariable']")) {
    $name = $n.GetAttribute('Include')
    $dv = $n.SelectSingleNode("*[local-name()='DefaultValue']")
    $val = if ($dv -and $dv.InnerText -and $dv.InnerText -notmatch '\$\(') { $dv.InnerText.Trim() } else { $name }
    if ($name) { $vars[$name] = $val }
  }
  $vars
}

# $(Name) tokens used by the source files (SQLCMD variables), case-insensitive.
function Get-SqlMigUsedVariables($Cfg) {
  $used = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($f in @(Get-SqlMigSourceFiles $Cfg)) {
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f.FullName), '\$\((?<v>[A-Za-z_][\w]*)\)')) { [void]$used.Add($m.Groups['v'].Value) }
  }
  @($used)
}

function Initialize-SqlMigConfig([string]$Project, [string]$Path = 'migration.config.json', [switch]$Force) {
  if ((Test-Path -LiteralPath $Path) -and -not $Force) { throw "$Path already exists - use -Force to overwrite it, or -Check to compare it with the project" }
  if (-not $Project) {
    $found = @(git ls-files '*.sqlproj' 2>$null) + @(Get-ChildItem -Recurse -Filter *.sqlproj -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.FullName.Substring((Get-Location).ProviderPath.TrimEnd('\', '/').Length + 1).Replace('\', '/') })
    $found = @($found | Where-Object { $_ -and $_ -notmatch '(^|/)(bin|obj)/' } | Select-Object -Unique)
    if ($found.Count -eq 0) { throw 'No .sqlproj found - pass -Project <path>' }
    if ($found.Count -gt 1) { throw "Several .sqlproj files: $($found -join ', ') - pass -Project <path>" }
    $Project = $found[0]
  }
  $Project = ConvertTo-SqlMigRelPath $Project
  if (-not (Test-Path -LiteralPath $Project)) { throw "Project $Project not found" }
  $cfg = Get-SqlMigDefaultConfig
  $cfg.project = $Project
  $cfg.database = [IO.Path]::GetFileNameWithoutExtension($Project)
  $cfg.sourceRoot = ConvertTo-SqlMigRelPath (Split-Path $Project -Parent)
  foreach ($cand in 'Migration', 'Migrations', 'migrations', 'migration') { if (Test-Path -LiteralPath $cand -PathType Container) { $cfg.migrationDir = $cand; break } }
  $head = (git symbolic-ref --quiet refs/remotes/origin/HEAD 2>$null)
  if ($head) { $cfg.baseBranch = ($head -replace '^refs/remotes/origin/', '') }
  else { foreach ($b in 'main', 'master') { git rev-parse --verify --quiet "refs/heads/$b" *> $null; if ($LASTEXITCODE -eq 0) { $cfg.baseBranch = $b; break } } }
  $global:LASTEXITCODE = 0
  $cfg.sqlcmdVariables = Get-SqlMigProjectVariables $Project
  foreach ($v in Get-SqlMigUsedVariables $cfg) {
    if (-not @($cfg.sqlcmdVariables.Keys | Where-Object { $_ -ieq $v }).Count) { $cfg.sqlcmdVariables[$v] = $v; Write-SqlMigNote warning "`$($v) is used in source but not declared in $Project - mapped to '$v'; correct it in $Path if the database name differs" }
  }
  $role = Find-SqlMigCiRole $cfg
  if ($role) { $cfg.ciRole = $role.Role; $cfg.ciRoleFile = $role.File }
  else { Write-SqlMigNote warning 'No role is granted ALTER ON SCHEMA in the Security folder - set ciRole/ciRoleFile by hand if new schemas need deploy-role grants' }
  $json = ($cfg | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"
  [IO.File]::WriteAllText((Join-Path (Get-Location).ProviderPath $Path), $json + "`n", (New-Object System.Text.UTF8Encoding $false))
  $cfg
}

# Drift between the configuration and the project as it is now. Errors would make the
# generated scripts wrong; warnings are follow-ups.
function Test-SqlMigConfigDrift($Cfg) {
  $errors = New-Object System.Collections.Generic.List[string]
  $warnings = New-Object System.Collections.Generic.List[string]
  if ($Cfg.project -and -not (Test-Path -LiteralPath $Cfg.project)) { $errors.Add("project $($Cfg.project) does not exist") }
  if (-not (Test-Path -LiteralPath $Cfg.sourceRoot)) { $errors.Add("sourceRoot $($Cfg.sourceRoot) does not exist") }
  if ($Cfg.ciRoleFile -and -not (Test-Path -LiteralPath $Cfg.ciRoleFile)) { $errors.Add("ciRoleFile $($Cfg.ciRoleFile) does not exist") }
  if ($Cfg.ciRoleFile -and -not $Cfg.ciRole) { $errors.Add('ciRoleFile is set but ciRole is not') }
  foreach ($v in Get-SqlMigUsedVariables $Cfg) {
    if (-not @($Cfg.sqlcmdVariables.Keys | Where-Object { $_ -ieq $v }).Count) { $errors.Add("`$($v) is used in source but has no entry in sqlcmdVariables - generated scripts would keep the raw token") }
  }
  foreach ($k in @($Cfg.sqlcmdVariables.Keys)) {
    if (-not @(Get-SqlMigUsedVariables $Cfg | Where-Object { $_ -ieq $k }).Count) { $warnings.Add("sqlcmdVariables maps `$($k), which no source file uses any more") }
  }
  if ($Cfg.ciRole -and $Cfg.ciRoleFile -and (Test-Path -LiteralPath $Cfg.ciRoleFile)) {
    $granted = Get-SqlMigRoleGrantedSchemas $Cfg
    foreach ($s in Get-SqlMigSchemaDirs $Cfg) {
      if ($granted -notcontains $s) { $warnings.Add("schema $s has no GRANT ALTER ON SCHEMA::[$s] to $($Cfg.ciRole) in $($Cfg.ciRoleFile) - run: sqlmig.ps1 project -Apply") }
    }
  }
  @{ Errors = @($errors); Warnings = @($warnings) }
}

# The repository-configuration section of the generation prompt (references/repo-config.md
# in a project that runs the generator from CI).
function Format-SqlMigRepoConfig($Cfg) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# Repository Configuration - $($Cfg.database)")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine('Generated by `sqlmig.ps1 init -RenderRepoConfig` from migration.config.json - edit that file, not this one.')
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("- **Database name** (used in file names and three-part names): ``$($Cfg.database)``")
  [void]$sb.AppendLine("- **Source folder**: ``$($Cfg.sourceRoot)``")
  if ($Cfg.project) { [void]$sb.AppendLine("- **SSDT project**: ``$($Cfg.project)``") }
  $role = if ($Cfg.ciRole) { "``$($Cfg.ciRole)``" } else { 'none configured - emit no schema-level deploy-role grants' }
  [void]$sb.AppendLine("- **CI/CD deploy role** (``ciRole``): $role")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine('## Schemas')
  [void]$sb.AppendLine()
  $schemas = @(Get-SqlMigSchemaDirs $Cfg)
  if ($schemas.Count) { foreach ($s in $schemas) { [void]$sb.AppendLine("- ``$s``") } } else { [void]$sb.AppendLine('- (none found)') }
  [void]$sb.AppendLine()
  [void]$sb.AppendLine('## SQLCMD Variable Mappings')
  [void]$sb.AppendLine()
  [void]$sb.AppendLine('Replace each `$(Variable)` (case-insensitive, with or without brackets) with the database name on the right. A variable can map to a name that differs from the variable itself: never assume the literal name.')
  [void]$sb.AppendLine()
  [void]$sb.AppendLine('| SQLCMD variable | Database name |')
  [void]$sb.AppendLine('|---|---|')
  if ($Cfg.sqlcmdVariables.Count) { foreach ($k in $Cfg.sqlcmdVariables.Keys) { [void]$sb.AppendLine("| ``$('$(' + $k + ')')`` | ``$($Cfg.sqlcmdVariables[$k])`` |") } }
  else { [void]$sb.AppendLine('| (none) | |') }
  $sb.ToString()
}

# ---------------------------------------------------------------------------------------
# context: what changed on this branch, and where the scripts go
# ---------------------------------------------------------------------------------------

function Get-SqlMigWorkDir {
  $p = (git rev-parse --git-path sqlmig 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $p) { throw 'Not a git repository' }
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
  (Resolve-Path -LiteralPath $p).ProviderPath
}

function Resolve-SqlMigBase($Cfg, [string]$Base) {
  $b = if ($Base) { $Base } else { $Cfg.baseBranch }
  $cands = if ($b -match '/') { @($b, "origin/$b") } else { @("origin/$b", $b) }
  foreach ($c in $cands) {
    git rev-parse --verify --quiet "$c^{commit}" *> $null
    if ($LASTEXITCODE -eq 0) {
      $mb = (git merge-base $c HEAD 2>$null)
      if ($LASTEXITCODE -ne 0 -or -not $mb) { throw "No merge base between $c and HEAD" }
      return @{ Ref = $c; MergeBase = "$mb".Trim() }
    }
  }
  $global:LASTEXITCODE = 0
  throw "Base branch '$b' not found (tried $($cands -join ', ')) - set baseBranch in migration.config.json or pass -Base"
}

function Get-SqlMigBranch {
  $b = (git rev-parse --abbrev-ref HEAD 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $b -or $b -eq 'HEAD') { throw 'HEAD is detached - check out the feature branch or pass -Branch' }
  "$b".Trim()
}

# Changed .sql files between the merge base and HEAD (-CommittedOnly) or the working tree,
# with rename detection; untracked files count as added.
function Get-SqlMigChanges($Cfg, [string]$MergeBase, [switch]$CommittedOnly) {
  $gitArgs = @('-c', 'core.quotePath=false', 'diff', '--name-status', '-z', '-M90%', $MergeBase)
  if ($CommittedOnly) { $gitArgs += 'HEAD' }
  $out = (& git @gitArgs -- @($Cfg.Pathspec)) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw "git diff failed (exit $LASTEXITCODE)" }
  $tok = @(if ($out) { $out.Split([char]0) } else { @() })
  $list = New-Object System.Collections.Generic.List[object]
  $i = 0
  while ($i -lt $tok.Count) {
    $st = $tok[$i].Trim()
    if (-not $st) { $i++; continue }
    if ($st -match '^[RC]') { $list.Add(@{ Status = $st; OldFile = $tok[$i + 1]; File = $tok[$i + 2] }); $i += 3 }
    else { $list.Add(@{ Status = $(if ($st -eq 'T') { 'M' } else { $st.Substring(0, 1) }); OldFile = $null; File = $tok[$i + 1] }); $i += 2 }
  }
  if (-not $CommittedOnly) {
    $untracked = (& git -c core.quotePath=false ls-files -z --others --exclude-standard -- @($Cfg.Pathspec)) -join "`n"
    foreach ($f in @(if ($untracked) { $untracked.Split([char]0) } else { @() })) {
      if ($f) { $list.Add(@{ Status = 'A'; OldFile = $null; File = $f }) }
    }
  }
  $global:LASTEXITCODE = 0
  , @($list | Sort-Object { $_.File })
}

# Schema and object folder of a source path: <...>/<schema>/<ObjectFolder>/<file>.sql.
function Get-SqlMigPathParts([string]$File) {
  $segs = $File.Split([char[]]@('/', '\'))
  for ($k = 0; $k -lt $segs.Count - 1; $k++) {
    if ($script:ObjectFolders -contains $segs[$k + 1]) {
      $folder = if ($segs[$k + 1] -eq 'Stored Procedure') { 'Stored Procedures' } else { $segs[$k + 1] }
      return @{ Schema = $segs[$k]; Folder = $folder }
    }
  }
  if ($segs -contains 'Security') { return @{ Schema = $null; Folder = 'Security' } }
  @{ Schema = $null; Folder = $null }
}

# True when every batch of the text is a GRANT, REVOKE or DENY.
function Test-SqlMigPermissionsOnly([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  $any = $false
  foreach ($b in ((Get-CodeView $Text) -split '(?m)^\s*GO\s*$')) {
    $c = $b.Trim()
    if (-not $c) { continue }
    if ($c -notmatch '(?i)\A(GRANT|REVOKE|DENY)\b' -or $c -match '(?i)\b(CREATE|ALTER|DROP)\s+') { return $false }
    $any = $true
  }
  $any
}

function Get-SqlMigNextVersion([string]$MigrationDir, [string]$OwnSuffix, [string]$First = 'V1.00001') {
  $null = $First -match '^V(\d+)\.(\d+)$'
  $width = $matches[2].Length
  $maxMinor = [int][Math]::Pow(10, $width) - 1
  $notes = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $MigrationDir)) { return @{ Version = $First; Notes = @() } }
  $groups = @{}; $parsed = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $MigrationDir -Filter 'V*.sql' -File -ErrorAction SilentlyContinue)) {
    # This branch's own scripts are about to be replaced: the version they hold is free.
    if ($OwnSuffix -and $f.Name.EndsWith($OwnSuffix, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($f.Name -notmatch '^V(\d+)\.(\d+)__') { $notes.Add("cannot parse a version from $($f.Name)"); continue }
    $o = [pscustomobject]@{ Major = [int]$matches[1]; Minor = [int]$matches[2]; Name = $f.Name }
    $parsed += $o
    $key = "V$($o.Major).$($o.Minor.ToString().PadLeft($width, '0'))"
    if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
    $groups[$key] += $f.Name
  }
  foreach ($k in $groups.Keys) { if ($groups[$k].Count -gt 1) { $notes.Add("duplicate version ${k}: $($groups[$k] -join ', ')") } }
  if ($parsed.Count -eq 0) { return @{ Version = $First; Notes = @($notes) } }
  $max = $parsed | Sort-Object Major, Minor | Select-Object -Last 1
  $major = $max.Major; $minor = $max.Minor + 1
  if ($minor -gt $maxMinor) { $major++; $minor = 1 }
  if ($major -gt 999) { throw 'Version overflow - the major version cannot exceed 999' }
  $next = "V$major.$($minor.ToString().PadLeft($width, '0'))"
  if ($groups.ContainsKey($next)) { throw "Next version $next already exists: $($groups[$next] -join ', ')" }
  @{ Version = $next; Notes = @($notes) }
}

function Get-SqlMigBranchScripts($Cfg, [string]$BranchSlug) {
  if (-not (Test-Path -LiteralPath $Cfg.migrationDir)) { return @() }
  $suffix = ".$($Cfg.database).$BranchSlug.sql"
  @(Get-ChildItem -LiteralPath $Cfg.migrationDir -File -Filter '*.sql' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) -and $_.Name -match '^(V\d+\.\d+|R)__' } |
    ForEach-Object { "$($Cfg.migrationDir)/$($_.Name)" })
}

function New-SqlMigContext($Cfg, [string]$Base, [string]$Branch, [string]$Date, [switch]$CommittedOnly) {
  $baseInfo = Resolve-SqlMigBase $Cfg $Base
  if (-not $Branch) { $Branch = Get-SqlMigBranch }
  $slug = $Branch -replace '[/\\]', '.'
  if (-not $Date) { $Date = Get-Date -Format 'yyyy-MM-dd' }
  $changes = Get-SqlMigChanges $Cfg $baseInfo.MergeBase -CommittedOnly:$CommittedOnly
  $mb = $baseInfo.MergeBase
  $files = [ordered]@{}
  $summary = @()
  foreach ($c in $changes) {
    $parts = Get-SqlMigPathParts $c.File
    $info = [ordered]@{ Status = $c.Status; File = $c.File }
    if ($c.OldFile) { $info.OldFile = $c.OldFile }
    $diffArgs = @($mb); if ($CommittedOnly) { $diffArgs += 'HEAD' }
    switch -Regex ($c.Status) {
      '^A$|^[RC]' {
        $info.Content = if (Test-Path -LiteralPath $c.File) { [IO.File]::ReadAllText((Resolve-Path -LiteralPath $c.File).ProviderPath) } else { (git cat-file -p "HEAD:$($c.File)" 2>$null) -join "`n" }
        $info.IsNew = $true
      }
      '^M$' {
        $info.Diff = (git -c core.quotePath=false diff @diffArgs -- $c.File) -join "`n"
        $info.Content = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $c.File).ProviderPath)
        $info.IsNew = $false
        git diff --quiet -w --ignore-blank-lines --ignore-cr-at-eol @diffArgs -- $c.File
        $info.WhitespaceOnly = ($LASTEXITCODE -eq 0)
      }
      '^D$' {
        $info.IsDeleted = $true
        $info.Content = (git cat-file -p "${mb}:$($c.File)" 2>$null) -join "`n"
      }
    }
    $global:LASTEXITCODE = 0
    # The deploy role's own file is managed out of band and never goes into a migration.
    $kind = if ($Cfg.ciRoleFile -and $c.File -ieq $Cfg.ciRoleFile) { 'ci-role' }
            elseif ($c.File -match $script:RepeatableFolderRx) { 'repeatable' }
            elseif (Test-SqlMigPermissionsOnly $info.Content) { 'permissions' }
            elseif ($parts.Folder -eq 'Security') { 'security' }
            elseif ($script:StructureFolders -contains $parts.Folder) { 'structure' }
            else { 'other' }
    $info.Schema = $parts.Schema; $info.Folder = $parts.Folder; $info.Kind = $kind
    $files[$c.File] = $info
    $summary += [pscustomobject]@{ Status = $c.Status; Kind = $kind; File = $c.File; WhitespaceOnly = [bool]$info.WhitespaceOnly }
  }
  $ver = Get-SqlMigNextVersion $Cfg.migrationDir ".$($Cfg.database).$slug.sql" $Cfg.firstVersion
  $versionCandidates = @($summary | Where-Object { $_.Kind -in @('structure', 'security', 'other') -and -not $_.WhitespaceOnly } | ForEach-Object { $_.File })
  [ordered]@{
    tool              = 'sql-migration-generator'
    database          = $Cfg.database
    sourceRoot        = $Cfg.sourceRoot
    migrationDir      = $Cfg.migrationDir
    branch            = $Branch
    branchSlug        = $slug
    baseRef           = $baseInfo.Ref
    mergeBase         = $mb
    committedOnly     = [bool]$CommittedOnly
    date              = $Date
    nextVersion       = $ver.Version
    versionNotes      = @($ver.Notes)
    versionFile       = "$($Cfg.migrationDir)/$($ver.Version)__$Date.$($Cfg.database).$slug.sql"
    repeatableFile    = "$($Cfg.migrationDir)/R__$Date.$($Cfg.database).$slug.sql"
    existingScripts   = @(Get-SqlMigBranchScripts $Cfg $slug)
    versionCandidates = $versionCandidates
    summary           = @($summary)
    changes           = $files
  }
}

function Save-SqlMigContext($Context) {
  $path = Join-Path (Get-SqlMigWorkDir) 'context.json'
  [IO.File]::WriteAllText($path, ($Context | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
  $path
}

function Read-SqlMigContext {
  $path = Join-Path (Get-SqlMigWorkDir) 'context.json'
  if (-not (Test-Path -LiteralPath $path)) { throw 'No context yet - run: sqlmig.ps1 context' }
  $ctx = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
  $head = (git rev-parse --abbrev-ref HEAD 2>$null)
  if ($head -and $head -ne 'HEAD' -and $ctx.branch -ne $head) { throw "The saved context is for branch '$($ctx.branch)' but HEAD is '$head' - run: sqlmig.ps1 context" }
  $ctx
}

# Delete this branch's previously generated scripts. A script with uncommitted edits is
# kept unless -Force: those edits would be lost with it.
function Remove-SqlMigBranchScripts([string[]]$Paths, [switch]$Force) {
  $removed = @(); $kept = @()
  foreach ($p in $Paths) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $dirty = (git status --porcelain -- $p 2>$null)
    $tracked = (git ls-files -- $p 2>$null)
    if ($tracked -and $dirty -and -not $Force) { $kept += $p; continue }
    Remove-Item -LiteralPath $p -Force
    $removed += $p
  }
  $global:LASTEXITCODE = 0
  @{ Removed = $removed; Kept = $kept }
}

# ---------------------------------------------------------------------------------------
# build: post-process the versioned script and build the repeatable one
# ---------------------------------------------------------------------------------------

# Replace $(Var) / [$(Var)] with the mapped database name, and a bare variable name left in
# a synonym's FOR clause when the database name differs. Returns the text and the
# variables it could not map.
function Convert-SqlMigVariables([string]$Text, $Cfg) {
  if (-not $Text) { return @{ Text = $Text; Unmapped = @() } }
  $dbNames = @{}
  foreach ($k in $Cfg.sqlcmdVariables.Keys) {
    $db = [string]$Cfg.sqlcmdVariables[$k]
    # A name that is not a regular identifier (a hyphen, a space) keeps its brackets.
    $dbNames[$k.ToLowerInvariant()] = if ($db -match '^[A-Za-z_][\w@#$]*$') { $db } else { "[$($db.Replace(']', ']]'))]" }
  }
  $unmapped = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $out = [regex]::Replace($Text, '\[?\$\((?<v>[A-Za-z_]\w*)\)\]?', {
      param($m)
      $v = $m.Groups['v'].Value
      if ($dbNames.ContainsKey($v.ToLowerInvariant())) { $dbNames[$v.ToLowerInvariant()] } else { [void]$unmapped.Add($v); $m.Value }
    }.GetNewClosure())
  foreach ($k in $Cfg.sqlcmdVariables.Keys) {
    $db = $dbNames[$k.ToLowerInvariant()]
    if ($db -ieq $k) { continue }
    $out = [regex]::Replace($out, "(?i)(\bFOR\s+)\[?$([regex]::Escape($k))\]?\.", { param($m) $m.Groups[1].Value + $db + '.' }.GetNewClosure())
  }
  @{ Text = $out; Unmapped = @($unmapped) }
}

# Object-level GRANT/REVOKE/DENY batches belong in the repeatable migration: take them out
# of the versioned one. Returns $null when nothing substantive is left.
function Remove-SqlMigObjectGrants([string]$Text, [ref]$RemovedCount) {
  $kept = @(); $removed = 0
  foreach ($batch in ($Text -split '(?m)^\s*GO\s*$')) {
    $trimmed = $batch.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    $sqlLines = $trimmed -split "`n" | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^\s*--' }
    $sqlOnly = ($sqlLines -join "`n").Trim()
    $hasObjectPermission = $sqlOnly -match '(?i)(GRANT|REVOKE|DENY)\s+\w+\s+ON\s+OBJECT::'
    $withoutPermissions = ($sqlLines | Where-Object { $_.Trim() -notmatch '(?i)^\s*(GRANT|REVOKE|DENY)\s+' }) -join "`n"
    $hasStructural = $withoutPermissions -match '(?i)(CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|MERGE|EXEC|TRUNCATE)\s+'
    if ($hasObjectPermission -and -not $hasStructural) { $removed++ } else { $kept += $trimmed }
  }
  $RemovedCount.Value = $removed
  $substantive = @($kept | Where-Object { (($_ -split "`n" | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^\s*--' }) -join '').Trim() })
  if ($substantive.Count -eq 0) { return $null }
  if ($removed -eq 0) { return $Text }
  ($kept -join "`nGO`n`n") + "`nGO"
}

function ConvertTo-SqlMigLineEndings([string]$Text, [string]$Style) {
  $lf = $Text -replace "`r`n", "`n" -replace "`r", "`n"
  if ($Style -eq 'lf') { $lf } else { $lf -replace "`n", "`r`n" }
}

# The repeatable migration, built deterministically from the changed source files, in
# dependency order (see references/dependency-ordering.md). Also adjusts the versioned
# script: drops what references a type before its DROP TYPE, and receives schema-level
# grants found in table/synonym/security files. Returns
# @{ Content; VersionContent; Objects; Order; Edges }; Content is $null when nothing is
# repeatable.
function Build-SqlMigRepeatable($Cfg, $Context, [string]$VersionContent) {
  $db = $Cfg.database
  $mergeBase = $Context.mergeBase
  $ciRoleFile = $Cfg.ciRoleFile
  $repeatableFiles = @()
  $deletedRepeatableObjects = @()
  $removedTriggers = @()

  foreach ($key in $Context.changes.Keys) {
    $c = $Context.changes[$key]
    $status = [string]$c.Status
    $file = [string]$c.File
    if ($status -ne 'D' -and $file -match $script:RepeatableFolderRx) {
      if (Test-Path -LiteralPath $file) {
        $normalizedType = if ($matches[1] -eq 'Stored Procedure') { 'Stored Procedures' } else { $matches[1] }
        $repeatableFiles += @{ File = $file; Status = $status; Type = $normalizedType }
      }
    }
    elseif ($status -ne 'D' -and $file -match '[/\\](Tables|Synonyms|Security|User Defined Types)[/\\]') {
      # The CI/CD deploy role is managed out of band: its grants are self-referential and
      # cannot be applied by the deploy login itself, so it never goes into a migration.
      if ($ciRoleFile -and $file -ieq $ciRoleFile) { continue }
      if (-not (Test-Path -LiteralPath $file)) { continue }
      $tempContent = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $file).ProviderPath)
      $fileTriggers = @()
      if ($file -match '([^/\\]+)[/\\]Tables[/\\]') {
        $fileSchema = $matches[1]
        $fileTriggers = @(Get-TableTriggers $tempContent $fileSchema)
        if ($status -eq 'M' -and $mergeBase) {
          $baseContent = (git cat-file -p "${mergeBase}:$file" 2>$null) -join "`n"
          $kept = @($fileTriggers | ForEach-Object { "$($_.Schema).$($_.Name)" })
          foreach ($t in @(Get-TableTriggers $baseContent $fileSchema)) {
            if ($kept -notcontains "$($t.Schema).$($t.Name)") { $removedTriggers += @{ Schema = $t.Schema; Name = $t.Name; SqlType = 'TRIGGER'; File = $file } }
          }
        }
      }
      if ($tempContent -match '(?i)(GRANT|REVOKE|DENY)\s+' -or $fileTriggers.Count -gt 0) {
        $repeatableFiles += @{ File = $file; Status = $status; Type = 'Permissions' }
      }
    }
    elseif ($status -eq 'D' -and $file -match '[/\\]([^/\\]+)[/\\](Views|Stored Procedures?|Functions|Triggers)[/\\]([^/\\]+)\.sql$') {
      $delSchema = $matches[1]; $delFolder = $matches[2]; $delName = $matches[3]
      $sqlType = switch -Wildcard ($delFolder) { 'Stored Procedure*' { 'PROCEDURE' } 'Views' { 'VIEW' } 'Functions' { 'FUNCTION' } 'Triggers' { 'TRIGGER' } }
      # The deleted file's own CREATE names the object when the path doesn't.
      if ($mergeBase) {
        $delDefined = Get-DefinedObject ((git cat-file -p "${mergeBase}:$file" 2>$null) -join "`n")
        if ($delDefined) { $delSchema = $delDefined.Schema; $delName = $delDefined.Name; $sqlType = $delDefined.Kind }
      }
      $deletedRepeatableObjects += @{ Schema = $delSchema; Name = $delName; SqlType = $sqlType; File = $file }
    }
    # A renamed repeatable file whose object name changed leaves the old object behind on
    # purpose: SKILL.md treats a rename as a new file and never drops for it.
  }
  $global:LASTEXITCODE = 0

  # Objects the V__ drops come back through the R__. Before each DROP TYPE, drop whatever
  # referenced the type at the merge base; every procedure, function, view or trigger the
  # V__ drops that still exists in source is re-created by the R__, which runs after it.
  $vContent = if ($VersionContent) { $VersionContent } else { '' }
  if ($vContent -match '(?i)\bDROP\s+(TYPE|PROC|PROCEDURE|FUNCTION|VIEW|TRIGGER)\b') {
    $catalogue = @{}
    foreach ($sf in @(Get-SqlMigSourceFiles $Cfg)) {
      if ($sf.Rel -match $script:RepeatableFolderRx) {
        $folderType = if ($matches[1] -like 'Stored Procedure*') { 'Stored Procedures' } else { $matches[1] }
        $d = Get-DefinedObject ([IO.File]::ReadAllText($sf.FullName))
        if ($d) { $catalogue[$d.Key] = @{ File = $sf.Rel; Type = $folderType } }
      } elseif ($sf.Rel -match '([^/\\]+)[/\\]Tables[/\\]') {
        foreach ($t in @(Get-TableTriggers ([IO.File]::ReadAllText($sf.FullName)) $matches[1])) { $catalogue[$t.Key] = @{ File = $sf.Rel; Type = 'Permissions' } }
      }
    }
    $dropRx = "(?i)\bDROP\s+(?<kind>TYPE|PROCEDURE|PROC|FUNCTION|VIEW|TRIGGER)\s+(?:IF\s+EXISTS\s+)?(?<names>$SqlDefName(?:\s*,\s*$SqlDefName)*)"
    $dropped = New-Object System.Collections.Generic.List[string]
    $newBatches = New-Object System.Collections.Generic.List[string]
    $insertedDrops = 0
    foreach ($b in ($vContent -split '(?m)^\s*GO\s*$')) {
      if ([string]::IsNullOrWhiteSpace($b)) { continue }
      foreach ($m in [regex]::Matches((Get-CodeView $b), $dropRx)) {
        foreach ($nm in [regex]::Matches($m.Groups['names'].Value, $SqlDefName)) {
          $k = ConvertTo-SqlKey $nm.Value
          if ($m.Groups['kind'].Value -notmatch '(?i)^TYPE$') { $dropped.Add($k.Key); continue }
          foreach ($dep in @(Get-TypeUsers $mergeBase $Cfg.Pathspec $k.Schema $k.Name)) {
            if ($dep.Kind -in @('TYPE', 'COLUMN')) {
              Write-SqlMigNote warning "$($dep.Path): $($dep.Kind.ToLower()) $($dep.Key) uses type $($k.Key) - the V__ must change it before it drops the type"
              continue
            }
            if ($dropped.Contains($dep.Key)) { continue }
            $newBatches.Add("-- Drop $($dep.Schema).$($dep.Name): it references type $($k.Schema).$($k.Name), dropped next; the repeatable migration re-creates it`nDROP $($dep.Kind) IF EXISTS [$($dep.Schema)].[$($dep.Name)];")
            $dropped.Add($dep.Key); $insertedDrops++
            Write-SqlMigNote info "V__: dropping [$($dep.Schema)].[$($dep.Name)] before DROP TYPE [$($k.Schema)].[$($k.Name)] (it references the type)"
          }
        }
      }
      $newBatches.Add($b.Trim())
    }
    if ($insertedDrops -gt 0) { $vContent = ($newBatches -join "`nGO`n`n") + "`nGO" }
    foreach ($key in ($dropped | Select-Object -Unique)) {
      $entry = $catalogue[$key]
      if (-not $entry -or @($repeatableFiles | Where-Object { $_.File -eq $entry.File }).Count) { continue }
      $repeatableFiles += @{ File = $entry.File; Status = 'M'; Type = $entry.Type }
      Write-SqlMigNote info "R__: re-creating $key from $($entry.File) - the V__ drops it"
    }
  }
  $global:LASTEXITCODE = 0

  # Drop each trigger a table file no longer defines, unless the branch still defines it
  # somewhere (say it moved to its own Triggers/ file). The search is loose on purpose: a
  # missed drop leaves the trigger as it was, but a wrong one would remove it.
  if ($removedTriggers.Count -gt 0) {
    $sourceFiles = @(Get-SqlMigSourceFiles $Cfg)
    $definedIn = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($sf in $sourceFiles) {
      foreach ($m in [regex]::Matches([IO.File]::ReadAllText($sf.FullName), '(?i)\bCREATE\s+(?:OR\s+ALTER\s+)?TRIGGER\s+(?:\[?\w+\]?\s*\.\s*)?\[?(\w+)\]?')) {
        if (-not $definedIn.ContainsKey($m.Groups[1].Value)) { $definedIn[$m.Groups[1].Value] = $sf.Rel }
      }
    }
    foreach ($t in $removedTriggers) {
      if ($sourceFiles.Count -eq 0) { Write-SqlMigNote warning "Could not read the source tree: trigger [$($t.Schema)].[$($t.Name)], removed from $($t.File), is not dropped" }
      elseif ($definedIn.ContainsKey($t.Name)) { Write-SqlMigNote info "Trigger [$($t.Schema)].[$($t.Name)] left $($t.File), but $($definedIn[$t.Name]) still has a CREATE TRIGGER for it: not dropped" }
      else { Write-SqlMigNote info "Trigger [$($t.Schema)].[$($t.Name)] was removed from $($t.File): dropping it"; $deletedRepeatableObjects += $t }
    }
  }

  if ($repeatableFiles.Count -eq 0 -and $deletedRepeatableObjects.Count -eq 0) {
    return @{ Content = $null; VersionContent = $(if ($vContent) { $vContent } else { $null }); Objects = 0; Order = @(); Edges = @() }
  }

  # ---- Dependency-aware ordering (references/dependency-ordering.md) ----
  # Tier priority: Functions (1) < Views (2) < SPs (3) < Triggers (4); a structure file's
  # grants and triggers ("Permissions") have no dependents, so tier 4 too.
  $tierOf = @{ 'Functions' = 1; 'Views' = 2; 'Stored Procedures' = 3; 'Triggers' = 4; 'Permissions' = 4 }

  # Step 1: each file's object, by its own CREATE statement with the path as fallback.
  $items = @(); $nameCount = @{}
  foreach ($fi in $repeatableFiles) {
    $segments = $fi.File -split '[/\\]'
    $schema = $null
    for ($k = 0; $k -lt $segments.Count - 1; $k++) {
      if ($segments[$k + 1] -in @('Tables', 'Views', 'Stored Procedures', 'Stored Procedure', 'Functions', 'Triggers', 'User Defined Types', 'Synonyms', 'Security')) { $schema = $segments[$k]; break }
    }
    if (-not $schema) { $schema = 'dbo' }
    $name = [IO.Path]::GetFileNameWithoutExtension($fi.File)
    $raw = if (Test-Path -LiteralPath $fi.File) { [IO.File]::ReadAllText((Resolve-Path -LiteralPath $fi.File).ProviderPath) } else { '' }
    if ($fi.Type -ne 'Permissions') {
      $defined = Get-DefinedObject $raw
      if ($defined) { $schema = $defined.Schema; $name = $defined.Name }
    }
    $id = "$schema.$name".ToLowerInvariant()
    $nameCount[$id] = 1 + [int]$nameCount[$id]
    $items += @{ File = $fi.File; Status = $fi.Status; Type = $fi.Type; Schema = $schema; Name = $name; Id = $id
      Node = $(if ($nameCount[$id] -eq 1) { $id } else { "$id#$($nameCount[$id])" }); Tier = $tierOf[$fi.Type]; Raw = $raw }
  }

  # Step 2: what each item's R__ batches reference (comments and literals don't count,
  # dynamic SQL does). A table file contributes only its grants and triggers.
  foreach ($it in $items) {
    $text = $it.Raw
    if ($it.Type -eq 'Permissions') {
      $text = if ($it.File -match '[/\\]Tables[/\\]') { (@(Get-TableTriggers $text $it.Schema) | ForEach-Object { $_.Batch }) -join "`nGO`n" } else { '' }
    }
    $it.Refs = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in @(Get-SqlReferences (Get-CodeView $text) $db)) { [void]$it.Refs.Add($r.Key) }
  }

  # Step 3: edges A -> B, "A references B". A table is never a target.
  $idToItem = @{}; $nodesOfId = @{}
  foreach ($it in $items) {
    $idToItem[$it.Node] = $it
    if ($it.Type -ne 'Permissions') { if (-not $nodesOfId.ContainsKey($it.Id)) { $nodesOfId[$it.Id] = @() }; $nodesOfId[$it.Id] += $it.Node }
  }
  $deps = @{}
  foreach ($it in $items) { $deps[$it.Node] = New-Object System.Collections.Generic.HashSet[string] }
  foreach ($it in $items) {
    foreach ($ref in $it.Refs) {
      if ($ref -eq $it.Id -or -not $nodesOfId.ContainsKey($ref)) { continue }
      foreach ($n in $nodesOfId[$ref]) { [void]$deps[$it.Node].Add($n) }
    }
  }
  # Must-precede: CREATE VIEW/FUNCTION resolve the views and functions they name when
  # created, and a function must exist before anything that calls it.
  function Test-MustPrecede($from, $to) { ($to.Type -eq 'Functions') -or ($to.Type -eq 'Views' -and $from.Type -in @('Views', 'Functions')) }

  # Step 4: order. Cycles are strongly connected components (Tarjan), sorted topologically
  # (Kahn) taking the ready component with the lowest (tier, name) first. Inside a cycle
  # only must-precede edges are enforced, then (tier, name).
  $nodes = @($deps.Keys | Sort-Object)
  $index = @{}; $low = @{}; $compOf = @{}
  $onStack = New-Object System.Collections.Generic.HashSet[string]
  $tarjan = New-Object System.Collections.Generic.Stack[string]
  $components = New-Object System.Collections.ArrayList
  $counter = 0
  foreach ($root in $nodes) {
    if ($index.ContainsKey($root)) { continue }
    $index[$root] = $counter; $low[$root] = $counter; $counter++
    $tarjan.Push($root); [void]$onStack.Add($root)
    $work = New-Object System.Collections.Generic.Stack[object]
    $work.Push([pscustomobject]@{ Node = $root; Next = @($deps[$root] | Sort-Object); At = 0 })
    while ($work.Count -gt 0) {
      $f = $work.Peek()
      if ($f.At -lt $f.Next.Count) {
        $w = $f.Next[$f.At]; $f.At++
        if (-not $index.ContainsKey($w)) {
          $index[$w] = $counter; $low[$w] = $counter; $counter++
          $tarjan.Push($w); [void]$onStack.Add($w)
          $work.Push([pscustomobject]@{ Node = $w; Next = @($deps[$w] | Sort-Object); At = 0 })
        } elseif ($onStack.Contains($w)) {
          $low[$f.Node] = [Math]::Min($low[$f.Node], $index[$w])
        }
      } else {
        [void]$work.Pop()
        if ($work.Count -gt 0) { $p = $work.Peek().Node; $low[$p] = [Math]::Min($low[$p], $low[$f.Node]) }
        if ($low[$f.Node] -eq $index[$f.Node]) {
          $members = New-Object System.Collections.Generic.List[string]
          do { $w = $tarjan.Pop(); [void]$onStack.Remove($w); $members.Add($w); $compOf[$w] = $components.Count } while ($w -ne $f.Node)
          [void]$components.Add($members)
        }
      }
    }
  }
  function Get-Rank([string]$node) { '{0}|{1}' -f $idToItem[$node].Tier, $node }
  $compDeps = @{}; $compUsers = @{}; $compRank = @{}
  for ($c = 0; $c -lt $components.Count; $c++) {
    $compDeps[$c] = New-Object System.Collections.Generic.HashSet[int]
    $compUsers[$c] = New-Object System.Collections.Generic.List[int]
    $compRank[$c] = $null
    foreach ($m in $components[$c]) { $r = Get-Rank $m; if ($null -eq $compRank[$c] -or [string]::CompareOrdinal($r, $compRank[$c]) -lt 0) { $compRank[$c] = $r } }
  }
  foreach ($v in $nodes) {
    foreach ($w in $deps[$v]) {
      if ($compOf[$v] -ne $compOf[$w] -and $compDeps[$compOf[$v]].Add($compOf[$w])) { $compUsers[$compOf[$w]].Add($compOf[$v]) }
    }
  }
  $pending = @{}; $ready = New-Object System.Collections.Generic.List[int]
  for ($c = 0; $c -lt $components.Count; $c++) { $pending[$c] = $compDeps[$c].Count; if ($pending[$c] -eq 0) { $ready.Add($c) } }
  $sortedIds = New-Object System.Collections.ArrayList
  $mustCycle = New-Object System.Collections.Generic.HashSet[string]
  while ($ready.Count -gt 0) {
    $best = 0
    for ($k = 1; $k -lt $ready.Count; $k++) { if ([string]::CompareOrdinal($compRank[$ready[$k]], $compRank[$ready[$best]]) -lt 0) { $best = $k } }
    $c = $ready[$best]; $ready.RemoveAt($best)
    $ranks = New-Object System.Collections.Generic.List[string]
    foreach ($x in $components[$c]) { $ranks.Add((Get-Rank $x)) }
    $ranks.Sort([StringComparer]::Ordinal)
    $members = @($ranks | ForEach-Object { $_.Substring($_.IndexOf('|') + 1) })
    if ($members.Count -eq 1) {
      [void]$sortedIds.Add($members[0])
    } else {
      $placed = New-Object System.Collections.Generic.HashSet[string]
      $left = New-Object System.Collections.Generic.List[string]; foreach ($x in $members) { $left.Add($x) }
      while ($left.Count -gt 0) {
        $pick = $null
        foreach ($x in $left) {
          $blocked = $false
          foreach ($d in $deps[$x]) { if ($left.Contains($d) -and -not $placed.Contains($d) -and (Test-MustPrecede $idToItem[$x] $idToItem[$d])) { $blocked = $true; break } }
          if (-not $blocked) { $pick = $x; break }
        }
        if (-not $pick) {
          Write-SqlMigNote warning "Views/functions reference each other in a cycle, so no order satisfies them all: $($left -join ', ')"
          foreach ($x in $left) { [void]$mustCycle.Add($x); [void]$sortedIds.Add($x) }
          break
        }
        [void]$sortedIds.Add($pick); [void]$placed.Add($pick); [void]$left.Remove($pick)
      }
      Write-SqlMigNote info "Dependency cycle among $($members.Count) objects: $($members -join ', '). Ordered by tier then name, views and functions after what they need."
    }
    foreach ($u in $compUsers[$c]) { $pending[$u]--; if ($pending[$u] -eq 0) { $ready.Add($u) } }
  }

  # Self-check: every object emitted once, every must-precede edge pointing backwards
  # unless both ends are in a reported cycle. A failure is a bug in the ordering.
  $posOf = @{}; for ($k = 0; $k -lt $sortedIds.Count; $k++) { $posOf[$sortedIds[$k]] = $k }
  if ($sortedIds.Count -ne $items.Count -or $posOf.Count -ne $items.Count) { throw "R__ ordering emitted $($sortedIds.Count) object(s) for $($items.Count) - not writing the migration" }
  $outOfOrder = @()
  foreach ($v in $nodes) {
    foreach ($w in $deps[$v]) {
      if ((Test-MustPrecede $idToItem[$v] $idToItem[$w]) -and $posOf[$w] -gt $posOf[$v] -and -not ($mustCycle.Contains($v) -and $mustCycle.Contains($w))) { $outOfOrder += "$v needs $w first" }
    }
  }
  if ($outOfOrder.Count -gt 0) { throw "R__ ordering bug: $($outOfOrder -join '; ') - not writing the migration" }

  $edges = @()
  foreach ($id in $deps.Keys) { foreach ($d in $deps[$id]) { $edges += "$id -> $d" } }

  $allParts = @(); $schemaGrantBatches = @(); $objectsBuilt = 0

  # DROPs first, so a CREATE OR ALTER of a surviving object cannot trip over a half-dropped
  # dependent - except an object that something in this R__ referenced at the merge base,
  # which is dropped after it (a schema-bound view must stop using a deleted function
  # first), unless the R__ re-creates the same name.
  $recreated = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($it in $items) {
    if ($it.Type -ne 'Permissions') { [void]$recreated.Add($it.Id) }
    elseif ($it.File -match '[/\\]Tables[/\\]') { foreach ($tr in @(Get-TableTriggers $it.Raw $it.Schema)) { [void]$recreated.Add($tr.Key) } }
  }
  $lateDrops = @()
  if ($mergeBase -and $deletedRepeatableObjects.Count -gt 0) {
    $baseRefs = @{}
    foreach ($it in $items) {
      if ($it.Status -ne 'M') { continue }
      $baseRefs[$it.Node] = @(Get-SqlReferences (Get-CodeView ((git cat-file -p "${mergeBase}:$($it.File)" 2>$null) -join "`n")) $db | ForEach-Object { $_.Key })
    }
    $global:LASTEXITCODE = 0
    foreach ($d in $deletedRepeatableObjects) {
      $dk = "$($d.Schema).$($d.Name)".ToLowerInvariant()
      if ($recreated.Contains($dk)) { continue }
      $users = @($baseRefs.Keys | Where-Object { $baseRefs[$_] -contains $dk })
      if ($users.Count) { $lateDrops += $d; Write-SqlMigNote info "DROP $($d.SqlType) [$($d.Schema)].[$($d.Name)] goes after $($users -join ', '), which used it" }
    }
  }
  $earlyDrops = @($deletedRepeatableObjects | Where-Object { $lateDrops -notcontains $_ })
  foreach ($d in ($earlyDrops | Sort-Object { $_.Schema }, { $_.Name })) {
    $allParts += "-- Drop $($d.Schema).$($d.Name)`nDROP $($d.SqlType) IF EXISTS [$($d.Schema)].[$($d.Name)];`nGO"
    $objectsBuilt++
  }

  foreach ($id in $sortedIds) {
    $it = $idToItem[$id]
    $sourceContent = $it.Raw
    if ([string]::IsNullOrWhiteSpace($sourceContent)) { Write-SqlMigNote warning "Empty source file $($it.File) - skipped"; continue }
    if ($it.Type -eq 'Permissions') {
      # Table/synonym/security/UDT files: the object itself belongs in V__, so keep only the
      # repeatable batches, in file order - GRANT/REVOKE/DENY and a table's triggers.
      $fileSchema = if ($it.File -match '([^/\\]+)[/\\]Tables[/\\]') { $matches[1] } else { $null }
      $keptBatches = @()
      foreach ($batch in ($sourceContent -split '(?m)^\s*GO\s*$')) {
        $trimmed = $batch.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $trigger = if ($fileSchema) { Get-BatchTrigger $trimmed $fileSchema } else { $null }
        if ($trigger) { $keptBatches += $trigger.Batch; continue }
        $batchHasPermission = $trimmed -match '(?i)(GRANT|REVOKE|DENY)\s+'
        $batchLines = $trimmed -split "`n" | Where-Object { $_.Trim() -notmatch '(?i)^\s*(GRANT|REVOKE|DENY)\s+' -and $_.Trim() -notmatch '^\s*--' -and $_.Trim() -ne '' }
        $batchHasStructure = ($batchLines -join "`n") -match '(?i)(CREATE|ALTER|DROP)\s+'
        if ($batchHasPermission -and -not $batchHasStructure) {
          # Schema-level grants go to the versioned migration; object grants stay here.
          if ($trimmed -match '(?i)\bON\s+SCHEMA::') { $schemaGrantBatches += $trimmed } else { $keptBatches += $trimmed }
        }
      }
      if ($keptBatches.Count -gt 0) {
        $allParts += ($keptBatches -join "`nGO`n`n").TrimEnd() + "`nGO"
        $objectsBuilt++
      }
    } else {
      # Views/procedures/functions/triggers: CREATE -> CREATE OR ALTER (a plain CREATE
      # fails on an existing object).
      $migrated = ($sourceContent -replace '(?i)\bCREATE\s+(VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\b', 'CREATE OR ALTER $1').Trim()
      if (-not $migrated.EndsWith('GO')) { $migrated += "`nGO" }
      $sourceGrants = [regex]::Matches($sourceContent, '(?i)GRANT\s+(SELECT|EXECUTE|EXEC)\b').Count
      $migratedGrants = [regex]::Matches($migrated, '(?i)GRANT\s+(SELECT|EXECUTE|EXEC)\b').Count
      if ($sourceGrants -ne $migratedGrants) { Write-SqlMigNote warning "$($it.File): GRANT count changed from $sourceGrants to $migratedGrants" }
      $allParts += $migrated
      $objectsBuilt++
    }
  }
  foreach ($d in $lateDrops) {
    $allParts += "-- Drop $($d.Schema).$($d.Name) (after what used it)`nDROP $($d.SqlType) IF EXISTS [$($d.Schema)].[$($d.Name)];`nGO"
    $objectsBuilt++
  }

  if ($schemaGrantBatches.Count -gt 0) {
    if (-not [string]::IsNullOrWhiteSpace($vContent)) {
      foreach ($sg in ($schemaGrantBatches | Select-Object -Unique)) { if (-not $vContent.Contains($sg)) { $vContent = $vContent.TrimEnd() + "`n`n" + $sg + "`nGO" } }
      Write-SqlMigNote info "Routed $(@($schemaGrantBatches | Select-Object -Unique).Count) schema-level grant batch(es) to the versioned migration"
    } else {
      Write-SqlMigNote warning 'Schema-level grants found but there is no versioned migration; keeping them in the repeatable one'
      $allParts += (($schemaGrantBatches | Select-Object -Unique) -join "`nGO`n`n") + "`nGO"
    }
  }

  if ($objectsBuilt -eq 0) { return @{ Content = $null; VersionContent = $(if ($vContent) { $vContent } else { $null }); Objects = 0; Order = @($sortedIds); Edges = $edges } }

  # A blank line between parts, so "GO" never shares a line with the next header.
  $built = ($allParts -join "`n`n").TrimEnd()

  # Self-check: every batch must be safe to run again.
  $notRerunnable = @()
  foreach ($b in ($built -split '(?m)^\s*GO\s*$')) {
    $code = [regex]::Replace($b.Trim(), '\A(?:\s|--[^\n]*|/\*.*?\*/)*', '', [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($code -and $code -notmatch '(?i)\A(CREATE\s+OR\s+ALTER\s+(VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\b|DROP\s+(VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\s+IF\s+EXISTS\b|GRANT\b|REVOKE\b|DENY\b|SET\s+\w+\s+(ON|OFF)\b)') {
      $notRerunnable += ($code -split "`n")[0].Trim()
    }
  }
  if ($notRerunnable.Count -gt 0) { throw "The repeatable migration has $($notRerunnable.Count) batch(es) that cannot be re-run - not writing it: $($notRerunnable -join ' | ')" }

  @{ Content = $built; VersionContent = $(if ($vContent) { $vContent } else { $null }); Objects = $objectsBuilt; Order = @($sortedIds); Edges = $edges }
}

# ---------------------------------------------------------------------------------------
# check: object order in the final scripts
# ---------------------------------------------------------------------------------------

function Get-SqlMigLineOf([int[]]$nl, [int]$pos) { $lo = 0; $hi = $nl.Count; while ($lo -lt $hi) { $mid = ($lo + $hi) -shr 1; if ($nl[$mid] -lt $pos) { $lo = $mid + 1 } else { $hi = $mid } }; $lo + 1 }

# Flyway runs the V__ and then the R__, each batch by batch top to bottom: every object
# must be created before anything that needs it, and nothing may be used after a drop.
# Returns @{ Errors; Warnings }; throws when the check itself cannot run.
function Test-SqlMigOrder($Cfg, $Context, [string]$vText, [string]$rText, [string]$vFile, [string]$rFile) {
  $db = $Cfg.database
  $errors = New-Object System.Collections.Generic.List[string]
  $warnings = New-Object System.Collections.Generic.List[string]
  $mergeBase = $Context.mergeBase
  $statusOf = @{}
  foreach ($k in $Context.changes.Keys) { $statusOf[[string]$Context.changes[$k].File] = ([string]$Context.changes[$k].Status).Substring(0, 1) }

  foreach ($pair in @(@{ T = $vText; F = $vFile }, @{ T = $rText; F = $rFile })) {
    if (-not $pair.T) { continue }
    foreach ($m in [regex]::Matches((Get-CodeView $pair.T), '\$\((?<v>[A-Za-z_]\w*)\)')) {
      $errors.Add("$($pair.F): SQLCMD variable `$($($m.Groups['v'].Value)) is still in the script - map it in sqlcmdVariables and run build again")
    }
  }

  $script:sqlmigCatalogue = $null
  $getCatalogue = {
    if ($null -ne $script:sqlmigCatalogue) { return $script:sqlmigCatalogue }
    $cat = @{}
    foreach ($sf in @(Get-SqlMigSourceFiles $Cfg)) {
      if ($sf.Rel -match $script:RepeatableFolderRx) {
        $d = Get-DefinedObject ([IO.File]::ReadAllText($sf.FullName))
        if ($d) { $cat[$d.Key] = @{ File = $sf.Rel; Kind = $d.Kind } }
      } elseif ($sf.Rel -match '([^/\\]+)[/\\]Tables[/\\]') {
        foreach ($tr in @(Get-TableTriggers ([IO.File]::ReadAllText($sf.FullName)) $matches[1])) { $cat[$tr.Key] = @{ File = $sf.Rel; Kind = 'TRIGGER' } }
      }
    }
    $script:sqlmigCatalogue = $cat
    $cat
  }

  # ---- R__: each batch re-runnable; views/functions after what they need
  $rDefs = @{}; $rSegments = @(); $rDropList = @()
  if ($rText) {
    $rCode = Get-CodeView $rText
    $rNl = @([regex]::Matches($rText, "`n") | ForEach-Object { $_.Index })
    $cuts = @(0) + @([regex]::Matches($rCode, '(?m)^\s*GO\s*$') | ForEach-Object { $_.Index + $_.Length }) + @($rCode.Length)
    for ($s = 0; $s -lt $cuts.Count - 1; $s++) {
      $len = $cuts[$s + 1] - $cuts[$s]
      $seg = $rCode.Substring($cuts[$s], $len) -replace '(?m)^\s*GO\s*$', ''
      $lead = $seg.Length - $seg.TrimStart().Length
      $code = $seg.Trim()
      if (-not $code) { continue }
      $at = $cuts[$s] + $lead
      $line = Get-SqlMigLineOf $rNl $at
      if ($code -match '(?i)\ACREATE\s+OR\s+ALTER\s+(VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\b') {
        $d = Get-DefinedObject ($rText.Substring($cuts[$s], $len) -replace '(?m)^\s*GO\s*$', '')
        if (-not $rDefs.ContainsKey($d.Key)) { $rDefs[$d.Key] = @{ Kind = $d.Kind; Pos = $at; Line = $line } }
        $rSegments += @{ Key = $d.Key; Kind = $d.Kind; Pos = $at; Line = $line; Code = $code; SchemaBound = $d.SchemaBound }
      } elseif ($code -match "(?i)\ADROP\s+(VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\s+IF\s+EXISTS\s+(?<name>$SqlDefName)" -or ($code -match "(?is)\AIF\b.*?\bDROP\s+(VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\s+(?:IF\s+EXISTS\s+)?(?<name>$SqlDefName)" -and $code -notmatch '(?i)\b(CREATE|ALTER|INSERT|UPDATE|DELETE|MERGE|TRUNCATE|EXEC(UTE)?)\b')) {
        $key = (ConvertTo-SqlKey $matches['name']).Key
        if ($rDefs.ContainsKey($key)) { $errors.Add("$rFile line ${line}: drops $key, which the same script created at line $($rDefs[$key].Line)") }
        $rDropList += @{ Key = $key; Pos = $at; Line = $line }
      } elseif ($code -notmatch '(?i)\A(GRANT|REVOKE|DENY)\b|\ASET\s+\w+\s+(ON|OFF)\b' -and -not ($code -match '(?is)\AIF\b.*\b(GRANT|REVOKE|DENY)\b' -and ([regex]::Replace($code, '(?is)\b(GRANT|REVOKE|DENY)\b.*?(?=;|\bEND\b|\z)', '')) -notmatch '(?i)\b(CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|MERGE|TRUNCATE|EXEC(UTE)?)\b')) {
        $errors.Add("$rFile line ${line}: '$((($code -split "`n")[0]).Trim())' cannot be re-run - a repeatable migration holds only CREATE OR ALTER, DROP ... IF EXISTS and GRANT/REVOKE/DENY")
      }
    }
    foreach ($sg in $rSegments) {
      foreach ($ref in @(Get-SqlReferences $sg.Code $db)) {
        if ($ref.Key -eq $sg.Key -or -not $rDefs.ContainsKey($ref.Key)) { continue }
        $dep = $rDefs[$ref.Key]
        if ((Test-SqlMustPrecede $sg.Kind $dep.Kind) -and $dep.Pos -gt $sg.Pos) { $errors.Add("$rFile line $($sg.Line): $($sg.Kind) $($sg.Key) needs $($dep.Kind) $($ref.Key), which is created later (line $($dep.Line))") }
      }
    }
    # A drop before a schema-bound object that used the dropped one (at the merge base)
    # fails: SQL Server refuses while the binding exists.
    foreach ($dr in $rDropList) {
      foreach ($sg in $rSegments) {
        if (-not $sg.SchemaBound -or $sg.Pos -lt $dr.Pos -or -not $mergeBase) { continue }
        $entry = (& $getCatalogue)[$sg.Key]
        if (-not $entry) { continue }
        $base = Get-CodeView ((git cat-file -p "${mergeBase}:$($entry.File)" 2>$null) -join "`n")
        if (@(Get-SqlReferences $base $db | Where-Object { $_.Key -eq $dr.Key }).Count) { $errors.Add("$rFile line $($dr.Line): drops $($dr.Key) before $($sg.Key) (line $($sg.Line)), which is schema-bound to it - the drop fails; it must come after") }
      }
    }
  }

  # ---- V__: created before use, not used after a drop, seeds before FKs
  $vCreated = @{}; $vDropped = New-Object System.Collections.Generic.List[object]; $uses = @(); $vFlat = $null
  if ($vText) {
    $vCode = Get-CodeView $vText
    $vNl = @([regex]::Matches($vText, "`n") | ForEach-Object { $_.Index })
    $nameSpans = New-Object 'System.Collections.Generic.HashSet[int]'
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($vCode, "(?i)\bCREATE\s+(?<kind>TABLE|TYPE|SYNONYM|SEQUENCE)\s+(?<name>$SqlDefName)")) {
      if ($m.Groups['name'].Value.StartsWith('#')) { continue }
      $k = ConvertTo-SqlKey $m.Groups['name'].Value
      $events.Add(@{ Pos = $m.Index; Key = $k.Key; Schema = $k.Schema; Name = $k.Name; Act = 'create'; Kind = $m.Groups['kind'].Value.ToUpperInvariant() }); [void]$nameSpans.Add($m.Groups['name'].Index)
    }
    $repeatableCreates = @()
    foreach ($m in [regex]::Matches($vCode, "(?i)\bCREATE\s+(?<alter>OR\s+ALTER\s+)?(?<kind>VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\s+(?<name>$SqlDefName)")) {
      $kind = if ($m.Groups['kind'].Value -like 'PROC*') { 'PROCEDURE' } else { $m.Groups['kind'].Value.ToUpperInvariant() }
      $k = ConvertTo-SqlKey $m.Groups['name'].Value
      $events.Add(@{ Pos = $m.Index; Key = $k.Key; Schema = $k.Schema; Name = $k.Name; Act = 'create'; Kind = $kind }); [void]$nameSpans.Add($m.Groups['name'].Index)
      $repeatableCreates += @{ Pos = $m.Index; Key = $k.Key; Kind = $kind; OrAlter = $m.Groups['alter'].Success }
    }
    foreach ($m in [regex]::Matches($vCode, "(?i)\bDROP\s+(?<kind>TABLE|TYPE|SYNONYM|SEQUENCE|VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\s+(?:IF\s+EXISTS\s+)?(?<names>$SqlDefName(?:\s*,\s*$SqlDefName)*)")) {
      $kind = if ($m.Groups['kind'].Value -like 'PROC*') { 'PROCEDURE' } else { $m.Groups['kind'].Value.ToUpperInvariant() }
      foreach ($nm in [regex]::Matches($m.Groups['names'].Value, $SqlDefName)) {
        $k = ConvertTo-SqlKey $nm.Value
        $events.Add(@{ Pos = $m.Index; Key = $k.Key; Schema = $k.Schema; Name = $k.Name; Act = 'drop'; Kind = $kind }); [void]$nameSpans.Add($m.Groups['names'].Index + $nm.Index)
      }
    }
    # An object rename (sp_rename 'schema.old', 'new') drops the old name and creates the
    # new one; renaming a column or an index changes neither.
    $q = [char]39
    foreach ($m in [regex]::Matches($vText, "(?i)\bsp_rename\s+(?:@objname\s*=\s*)?N?$q(?<old>[^$q]+)$q\s*,\s*(?:@newname\s*=\s*)?N?$q(?<new>[^$q]+)$q(?<rest>[^\r\n;]*)")) {
      if ($m.Groups['rest'].Value -match "(?i)$q(COLUMN|INDEX|STATISTICS|USERDATATYPE)$q") { continue }
      $old = ConvertTo-SqlKey $m.Groups['old'].Value
      if (@(Split-SqlName $m.Groups['old'].Value).Count -gt 2) { continue }
      $newName = @(Split-SqlName $m.Groups['new'].Value)[-1]
      $events.Add(@{ Pos = $m.Index; Key = $old.Key; Schema = $old.Schema; Name = $old.Name; Act = 'drop'; Kind = 'RENAME' })
      $events.Add(@{ Pos = $m.Index + 1; Key = "$($old.Schema).$newName".ToLowerInvariant(); Schema = $old.Schema; Name = $newName; Act = 'create'; Kind = 'RENAME' })
    }
    $schemaEvents = @{}; $roleEvents = @{}
    foreach ($m in [regex]::Matches($vCode, "(?i)\bCREATE\s+SCHEMA\s+(?<name>$SqlDefPart)")) { $k = (@(Split-SqlName $m.Groups['name'].Value)[0]).ToLowerInvariant(); if (-not $schemaEvents.ContainsKey($k)) { $schemaEvents[$k] = $m.Index } }
    foreach ($m in [regex]::Matches($vCode, "(?i)\bCREATE\s+ROLE\s+(?<name>$SqlDefPart)")) { $k = (@(Split-SqlName $m.Groups['name'].Value)[0]).ToLowerInvariant(); if (-not $roleEvents.ContainsKey($k)) { $roleEvents[$k] = $m.Index } }
    $uses = @(Get-SqlReferences $vCode $db | ForEach-Object { @{ Pos = $_.Pos; Key = $_.Key; Named = $nameSpans.Contains($_.Pos) } })
    $byKey = @{}
    foreach ($e in ($events | Sort-Object { $_.Pos })) { if (-not $byKey.ContainsKey($e.Key)) { $byKey[$e.Key] = New-Object System.Collections.Generic.List[object] }; $byKey[$e.Key].Add($e) }
    # A table/type/synonym/sequence existed before this script when a source file defines
    # it and that file is not new on this branch.
    $script:sqlmigStructure = $null
    $getStructure = {
      if ($null -ne $script:sqlmigStructure) { return $script:sqlmigStructure }
      $st = @{}
      $createRx = "(?i)\bCREATE\s+(?:TABLE|TYPE|SYNONYM|SEQUENCE)\s+(?<n>$SqlDefName)"
      foreach ($sf in @(Get-SqlMigSourceFiles $Cfg)) {
        $raw = [IO.File]::ReadAllText($sf.FullName)
        if ($raw -notmatch $createRx) { continue }
        foreach ($sm in [regex]::Matches((Get-CodeView $raw), $createRx)) {
          if ($sm.Groups['n'].Value.StartsWith('#')) { continue }
          $st[(ConvertTo-SqlKey $sm.Groups['n'].Value).Key] = $sf.Rel
        }
      }
      $script:sqlmigStructure = $st
      $st
    }
    $existedBefore = { param([string]$key) $file = (& $getStructure)[$key]; if (-not $file) { $e = (& $getCatalogue)[$key]; if ($e) { $file = $e.File } }; [bool]$file -and $statusOf[$file] -ne 'A' }
    $droppedBefore = { param([string]$key, [int]$pos) $byKey.ContainsKey($key) -and @($byKey[$key] | Where-Object { $_.Act -eq 'drop' -and $_.Pos -lt $pos }).Count -gt 0 }
    foreach ($rc in $repeatableCreates) {
      $line = Get-SqlMigLineOf $vNl $rc.Pos
      $entry = (& $getCatalogue)[$rc.Key]
      $existed = $entry -and ($statusOf[$entry.File] -ne 'A')
      if (-not $rc.OrAlter -and $existed -and -not (& $droppedBefore $rc.Key $rc.Pos)) { $errors.Add("$vFile line ${line}: CREATE $($rc.Kind) $($rc.Key) fails - it already exists (it is in $($entry.File) before this branch); it belongs in the repeatable migration") }
      else { $warnings.Add("$vFile line ${line}: $($rc.Kind) $($rc.Key) is created in the versioned migration - repeatable objects belong in the R__") }
    }
    foreach ($u in $uses) {
      if ($u.Named -or -not $byKey.ContainsKey($u.Key)) { continue }
      $evs = $byKey[$u.Key]
      $last = $null; foreach ($e in $evs) { if ($e.Pos -lt $u.Pos) { $last = $e } }
      $line = Get-SqlMigLineOf $vNl $u.Pos
      if ($null -eq $last) {
        if ($evs[0].Act -eq 'create' -and -not (& $existedBefore $u.Key)) { $errors.Add("$vFile line ${line}: uses $($u.Key) before it is created (line $(Get-SqlMigLineOf $vNl $evs[0].Pos))") }
      } elseif ($last.Act -eq 'drop') {
        $errors.Add("$vFile line ${line}: uses $($u.Key) after it is dropped (line $(Get-SqlMigLineOf $vNl $last.Pos))")
      }
    }
    $batchStarts = @(0) + @([regex]::Matches($vText, '(?im)^[ \t]*GO[ \t]*\r?$') | ForEach-Object { $_.Index + $_.Length })
    $getBatchStart = { param([int]$pos) $st = 0; foreach ($b in $batchStarts) { if ($b -le $pos) { $st = $b } else { break } }; $st }
    $getBatchEnd = { param([int]$pos) foreach ($b in $batchStarts) { if ($b -gt $pos) { return $b } }; $vText.Length }
    # An unguarded CREATE of a table/type/synonym/sequence fails when it already exists
    # (Msg 2714/219), unless this script dropped it first.
    foreach ($e in $events) {
      if ($e.Act -ne 'create' -or $e.Kind -notin 'TABLE', 'TYPE', 'SYNONYM', 'SEQUENCE') { continue }
      $bs = & $getBatchStart $e.Pos
      if ($vCode.Substring($bs, $e.Pos - $bs) -match '(?i)\bIF\b') { continue }
      if ((& $existedBefore $e.Key) -and -not (& $droppedBefore $e.Key $e.Pos)) { $errors.Add("$vFile line $(Get-SqlMigLineOf $vNl $e.Pos): CREATE $($e.Kind) $($e.Key) fails - it already exists and nothing drops it first; guard it (IF ... IS NULL) or drop it before") }
    }
    # A column this script adds (ALTER TABLE t ADD c) can't be used before the ADD, nor by DML
    # later in the same batch: SQL Server compiles the batch before the ALTER runs (Msg 207).
    foreach ($m in [regex]::Matches($vCode, "(?i)\bALTER\s+TABLE\s+(?<t>$SqlDefName)\s+(?:WITH\s+(?:NO)?CHECK\s+)?ADD\s+(?<c>\[[^\]]+\]|[A-Za-z_][\w@#$]*)")) {
      $col = $m.Groups['c'].Value.Trim('[', ']')
      if ($col -match '^(?i:CONSTRAINT|PRIMARY|FOREIGN|UNIQUE|CHECK|INDEX|DEFAULT|PERIOD)$') { continue }
      $tk = (ConvertTo-SqlKey $m.Groups['t'].Value).Key
      $colRx = "(?i)(?<![\w@#$])(?:\[$([regex]::Escape($col))\]|$([regex]::Escape($col)))(?![\w@#$])"
      $createdAt = @($events | Where-Object { $_.Key -eq $tk -and $_.Act -eq 'create' -and $_.Pos -lt $m.Index }) | Select-Object -Last 1
      if ($createdAt) {
        $cs = $createdAt.Pos
        if ($vCode.Substring($cs, (& $getBatchEnd $cs) - $cs) -match $colRx) { continue }
      } else {
        if (-not (& $existedBefore $tk)) { continue }
        $tFile = (& $getStructure)[$tk]
        if ($mergeBase -and $tFile) {
          $baseDef = Get-CodeView ((git cat-file -p "${mergeBase}:$tFile" 2>$null) -join "`n"); $global:LASTEXITCODE = 0
          if ($baseDef -match $colRx) { continue }
        }
      }
      $from = if ($createdAt) { $createdAt.Pos } else { -1 }
      $addAt = $m.Groups['c'].Index; $addBatch = & $getBatchStart $m.Index
      if ($null -eq $vFlat) {
        $sb = New-Object System.Text.StringBuilder $vText
        foreach ($lm in $SqlLexRx.Matches($vText)) {
          if ($lm.Value[0] -eq '[' -or $lm.Value[0] -eq '"') { continue }
          for ($i = $lm.Index; $i -lt $lm.Index + $lm.Length; $i++) { if ($vText[$i] -ne "`n" -and $vText[$i] -ne "`r") { $sb[$i] = ' ' } }
        }
        $vFlat = $sb.ToString()
      }
      $hit = $null
      foreach ($u in @($uses | Where-Object { $_.Key -eq $tk -and $_.Pos -gt $from -and $_.Pos -lt (& $getBatchEnd $m.Index) })) {
        $bs = & $getBatchStart $u.Pos; $be = & $getBatchEnd $u.Pos
        foreach ($cm in [regex]::Matches($vCode.Substring($bs, $be - $bs), $colRx)) {
          $at = $bs + $cm.Index
          if ($at -eq $addAt) { continue }
          if ($bs -eq $addBatch -and $at -gt $addAt) {
            if ($vFlat[$at] -eq ' ') { continue }
            $stmt = [regex]::Matches($vFlat.Substring($bs, $at - $bs), '(?i)\b(UPDATE|INSERT|SELECT|DELETE|MERGE|CREATE|ALTER)\b') | Select-Object -Last 1
            if (-not $stmt -or $stmt.Value -match '(?i)^(CREATE|ALTER)$') { continue }
          }
          $hit = $at; break
        }
        if ($null -ne $hit) { break }
      }
      if ($null -ne $hit) { $errors.Add("$vFile line $(Get-SqlMigLineOf $vNl $hit): uses column $tk.$($col.ToLowerInvariant()) before it is added (line $(Get-SqlMigLineOf $vNl $m.Index)); a use in the same batch fails too - put it after a GO") }
    }
    foreach ($sc in $schemaEvents.Keys) {
      foreach ($u in $uses) { if ($u.Key.StartsWith("$sc.") -and $u.Pos -lt $schemaEvents[$sc]) { $errors.Add("$vFile line $(Get-SqlMigLineOf $vNl $u.Pos): uses schema $sc before it is created (line $(Get-SqlMigLineOf $vNl $schemaEvents[$sc]))"); break } }
      foreach ($m in [regex]::Matches($vCode, "(?i)\bSCHEMA\s*::\s*(?<name>$SqlDefPart)")) {
        if ((@(Split-SqlName $m.Groups['name'].Value)[0]).ToLowerInvariant() -eq $sc -and $m.Index -lt $schemaEvents[$sc]) { $errors.Add("$vFile line $(Get-SqlMigLineOf $vNl $m.Index): grants on schema $sc before it is created (line $(Get-SqlMigLineOf $vNl $schemaEvents[$sc]))") }
      }
    }
    foreach ($r in $roleEvents.Keys) {
      foreach ($m in [regex]::Matches($vCode, "(?i)\b(?:TO|ALTER\s+ROLE|AUTHORIZATION)\s+(?<name>$SqlDefPart)")) {
        if ((@(Split-SqlName $m.Groups['name'].Value)[0]).ToLowerInvariant() -eq $r -and $m.Index -lt $roleEvents[$r]) { $errors.Add("$vFile line $(Get-SqlMigLineOf $vNl $m.Index): uses role $r before it is created (line $(Get-SqlMigLineOf $vNl $roleEvents[$r]))") }
      }
    }
    # A lookup table this script creates and seeds must be seeded before a foreign key on an
    # existing table validates against it (error 547 on any environment with data).
    $tableStmts = @([regex]::Matches($vCode, "(?i)\b(?<verb>ALTER|CREATE)\s+TABLE\s+(?<name>$SqlDefName)") | ForEach-Object { @{ Pos = $_.Index; Verb = $_.Groups['verb'].Value.ToUpperInvariant(); Key = (ConvertTo-SqlKey $_.Groups['name'].Value).Key } })
    $seedPos = @{}
    foreach ($m in [regex]::Matches($vCode, "(?i)\b(?:INSERT\s+(?:INTO\s+)?|MERGE\s+(?:INTO\s+)?)(?<name>$SqlDefName)")) { $k = (ConvertTo-SqlKey $m.Groups['name'].Value).Key; if (-not $seedPos.ContainsKey($k)) { $seedPos[$k] = $m.Index } }
    foreach ($m in [regex]::Matches($vCode, "(?i)\bREFERENCES\s+(?<name>$SqlDefName)")) {
      $ref = (ConvertTo-SqlKey $m.Groups['name'].Value).Key
      if (-not $seedPos.ContainsKey($ref) -or -not $byKey.ContainsKey($ref) -or -not (@($byKey[$ref] | Where-Object { $_.Act -eq 'create' -and $_.Kind -eq 'TABLE' }).Count)) { continue }
      $stmt = $null; foreach ($ts in $tableStmts) { if ($ts.Pos -lt $m.Index) { $stmt = $ts } }
      if (-not $stmt -or $stmt.Verb -ne 'ALTER') { continue }
      $created = $byKey.ContainsKey($stmt.Key) -and @($byKey[$stmt.Key] | Where-Object { $_.Act -eq 'create' }).Count
      if (-not $created -and $m.Index -lt $seedPos[$ref]) {
        $stmtText = $vCode.Substring($stmt.Pos, $m.Index - $stmt.Pos)
        $msg = "$vFile line $(Get-SqlMigLineOf $vNl $m.Index): the foreign key on $($stmt.Key) to $ref comes before $ref is seeded (line $(Get-SqlMigLineOf $vNl $seedPos[$ref]))"
        if ($stmtText -match '(?i)\bWITH\s+NOCHECK\b') { }
        elseif ($stmtText -match '(?i)\bADD\s+CONSTRAINT\s+\S+\s+FOREIGN\s+KEY\b' -or ($stmtText -match '(?i)\bNOT\s+NULL\b' -and $stmtText -match '(?i)\bDEFAULT\b')) { $errors.Add("$msg - existing rows are validated against it, so on an environment with data it fails with error 547") }
        else { $warnings.Add("$msg - seed it first") }
      }
    }
    # Flyway runs a versioned script in one transaction: an ONLINE index build on a table the
    # same script altered first inherits that ALTER's schema lock, so it is effectively
    # offline (SQL Server message 1970). Harmless on a small table, an outage on a hot one.
    $alters = @([regex]::Matches($vCode, "(?i)\bALTER\s+TABLE\s+(?<t>$SqlDefName)") | ForEach-Object { @{ Pos = $_.Index; Key = (ConvertTo-SqlKey $_.Groups['t'].Value).Key } })
    foreach ($m in [regex]::Matches($vCode, "(?is)\bCREATE\s+(?:UNIQUE\s+)?(?:NON)?CLUSTERED\s+INDEX\s+$SqlDefPart\s+ON\s+(?<t>$SqlDefName)(?:(?!\bGO\b).)*?\bONLINE\s*=\s*ON\b")) {
      $tk = (ConvertTo-SqlKey $m.Groups['t'].Value).Key
      $prior = @($alters | Where-Object { $_.Key -eq $tk -and $_.Pos -lt $m.Index }) | Select-Object -First 1
      if ($prior -and -not (@($events | Where-Object { $_.Key -eq $tk -and $_.Act -eq 'create' -and $_.Kind -eq 'TABLE' }).Count)) {
        $warnings.Add("$vFile line $(Get-SqlMigLineOf $vNl $m.Index): the ONLINE index on $tk follows an ALTER TABLE on it (line $(Get-SqlMigLineOf $vNl $prior.Pos)); Flyway runs the script in one transaction, so the ALTER's schema lock is still held and the build blocks the table (SQL Server message 1970). On a large or busy table, ship the index in its own migration")
      }
    }
    foreach ($e in $events) { if ($e.Act -eq 'create' -and -not $vCreated.ContainsKey($e.Key)) { $vCreated[$e.Key] = $e } }
    foreach ($k in $byKey.Keys) { $evs = $byKey[$k]; $lastEv = $evs[$evs.Count - 1]; if ($lastEv.Act -eq 'drop' -and $lastEv.Kind -ne 'RENAME') { $vDropped.Add($lastEv) } }

    # A dropped type: what used it at the merge base must go first. A dropped table: other
    # tables' foreign keys to it likewise.
    foreach ($d in $events) {
      if ($d.Act -ne 'drop' -or $d.Kind -notin @('TYPE', 'TABLE') -or -not $mergeBase) { continue }
      $line = Get-SqlMigLineOf $vNl $d.Pos
      if ($d.Kind -eq 'TYPE') {
        foreach ($u in @(Get-TypeUsers $mergeBase $Cfg.Pathspec $d.Schema $d.Name)) {
          if ($u.Kind -eq 'COLUMN') {
            $changed = @($tableStmts | Where-Object { $_.Key -eq $u.Key -and $_.Verb -eq 'ALTER' -and $_.Pos -lt $d.Pos }).Count -or (& $droppedBefore $u.Key $d.Pos)
            if (-not $changed) { $errors.Add("$vFile line ${line}: DROP TYPE $($d.Key) fails - table $($u.Key) has a column of it; change that column first") }
          } elseif (-not (& $droppedBefore $u.Key $d.Pos)) {
            $how = if ($u.Kind -eq 'TYPE') { 'drop it first, and re-create it after' } else { 'drop it first (the repeatable migration re-creates it)' }
            $errors.Add("$vFile line ${line}: DROP TYPE $($d.Key) fails - $($u.Kind.ToLower()) $($u.Key) still uses it; $how")
          }
        }
      } else {
        foreach ($fk in @(Get-ForeignKeysTo $mergeBase $Cfg.Pathspec $d.Schema $d.Name)) {
          if (& $droppedBefore $fk.Owner $d.Pos) { continue }
          if ($fk.Constraint) {
            $gone = @([regex]::Matches($vCode, "(?i)\bDROP\s+CONSTRAINT\s+(?:IF\s+EXISTS\s+)?(?<c>$SqlDefPart)") | Where-Object { (@(Split-SqlName $_.Groups['c'].Value)[0]) -ieq $fk.Constraint -and $_.Index -lt $d.Pos }).Count
            if (-not $gone) { $errors.Add("$vFile line ${line}: DROP TABLE $($d.Key) fails - foreign key $($fk.Constraint) on $($fk.Owner) still references it; drop the constraint first") }
          } else {
            $ownerName = ($fk.Owner -split '\.', 2)[1]
            $before = $vText.Substring(0, $d.Pos)
            if (-not ($before -match '(?i)\bDROP\s+CONSTRAINT\b' -and $before -match ('(?i)' + [regex]::Escape($ownerName)) -and $before -match '(?i)\bsys\.foreign_keys\b')) {
              $errors.Add("$vFile line ${line}: DROP TABLE $($d.Key) fails - an unnamed foreign key on $($fk.Owner) still references it; drop that key first (look it up in sys.foreign_keys)")
            }
          }
        }
      }
    }

    # An object this branch adds as a repeatable one does not exist yet while the V__ runs.
    $added = @{}
    foreach ($f in $statusOf.Keys) {
      if ($statusOf[$f] -eq 'A' -and $f -match $script:RepeatableFolderRx -and (Test-Path -LiteralPath $f)) {
        $o = Get-DefinedObject ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $f).ProviderPath)); if ($o) { $added[$o.Key] = $o.Kind }
      }
    }
    foreach ($u in $uses) {
      if ($u.Named -or -not $added.ContainsKey($u.Key) -or $vCreated.ContainsKey($u.Key)) { continue }
      $errors.Add("$vFile line $(Get-SqlMigLineOf $vNl $u.Pos): uses $($added[$u.Key]) $($u.Key), which this branch adds in the repeatable migration - Flyway runs that after the versioned one, so it does not exist yet. Ship $($u.Key) in an earlier change")
    }
    $gone = @{}; foreach ($x in $vDropped) { if (-not $rDefs.ContainsKey($x.Key)) { $gone[$x.Key] = $x } }
    foreach ($sg in $rSegments) {
      if ($sg.Kind -notin @('VIEW', 'FUNCTION')) { continue }
      foreach ($ref in @(Get-SqlReferences $sg.Code $db)) {
        if ($gone.ContainsKey($ref.Key)) { $errors.Add("$rFile line $($sg.Line): $($sg.Kind) $($sg.Key) references $($ref.Key), which the versioned migration drops (line $(Get-SqlMigLineOf $vNl $gone[$ref.Key].Pos))") }
      }
    }
    foreach ($x in $vDropped) {
      if ($x.Kind -notin @('PROCEDURE', 'FUNCTION', 'VIEW', 'TRIGGER')) { continue }
      $entry = (& $getCatalogue)[$x.Key]
      if ($entry -and -not $rDefs.ContainsKey($x.Key)) { $errors.Add("$vFile line $(Get-SqlMigLineOf $vNl $x.Pos): drops $($x.Kind) $($x.Key), which is still in $($entry.File), and the repeatable migration does not re-create it - it would be missing after the deployment") }
    }
  }
  $global:LASTEXITCODE = 0
  @{ Errors = @($errors | Select-Object -Unique); Warnings = @($warnings | Select-Object -Unique) }
}

# ---------------------------------------------------------------------------------------
# project: deploy-role grants for new schemas, and the .sqlproj item list
# ---------------------------------------------------------------------------------------

function Get-SqlMigRoleGrantedSchemas($Cfg) {
  $code = Get-CodeView ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $Cfg.ciRoleFile).ProviderPath))
  @([regex]::Matches($code, "(?i)\bGRANT\s+ALTER\s+ON\s+SCHEMA\s*::\s*(?<s>$SqlPart)\s+TO\s+(?<r>$SqlPart)") |
    Where-Object { (@(Split-SqlName $_.Groups['r'].Value)[0]) -ieq $Cfg.ciRole } |
    ForEach-Object { @(Split-SqlName $_.Groups['s'].Value)[0] } | Select-Object -Unique)
}

# Adds the seven schema grants (ALTER, SELECT, INSERT, UPDATE, DELETE, EXECUTE,
# REFERENCES) for every schema folder the deploy role lacks, before the Flyway table grants.
function Update-SqlMigRoleFile($Cfg, [switch]$Apply) {
  if (-not $Cfg.ciRole -or -not $Cfg.ciRoleFile) { return @{ Changed = $false; Schemas = @(); Reason = 'ciRole/ciRoleFile not configured' } }
  if (-not (Test-Path -LiteralPath $Cfg.ciRoleFile)) { return @{ Changed = $false; Schemas = @(); Reason = "$($Cfg.ciRoleFile) not found" } }
  $granted = Get-SqlMigRoleGrantedSchemas $Cfg
  $missing = @(Get-SqlMigSchemaDirs $Cfg | Where-Object { $granted -notcontains $_ } | Sort-Object)
  if ($missing.Count -eq 0) { return @{ Changed = $false; Schemas = @(); Reason = 'every schema folder is granted' } }
  if ($Apply) {
    $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Cfg.ciRoleFile).ProviderPath)
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]($text -split '\r?\n')
    $at = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '(?i)GRANT\s+\w+.*\bON\s+(OBJECT::)?\[?dbo\]?\.\[?flyway_schema_history') { $at = $i; break } }
    $new = @()
    foreach ($s in $missing) { foreach ($perm in 'ALTER', 'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'EXECUTE', 'REFERENCES') { $new += "GRANT $perm ON SCHEMA::[$s] TO [$($Cfg.ciRole)];"; $new += 'GO'; $new += '' } }
    if ($at -lt 0) { if ($lines.Count -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }; $lines.AddRange([string[]]$new) } else { $lines.InsertRange($at, [string[]]$new) }
    [IO.File]::WriteAllText((Resolve-Path -LiteralPath $Cfg.ciRoleFile).ProviderPath, ($lines -join $nl), (New-Object System.Text.UTF8Encoding $false))
  }
  @{ Changed = [bool]$Apply; Schemas = $missing; Reason = $null }
}

function Test-SqlMigMsbuildWildcard([string]$Pattern, [string]$Path) {
  $rx = '^' + ([regex]::Escape($Pattern.Replace('/', '\')) -replace '\\\*\\\*\\\\', '(?:.*\\)?' -replace '\\\*\\\*', '.*' -replace '\\\*', '[^\\]*' -replace '\\\?', '[^\\]') + '$'
  $Path.Replace('/', '\') -match "(?i)$rx"
}

# Keeps a non-SDK .sqlproj in step with the branch: an explicit item for each new file no
# existing item covers (<Build> for schema objects and Security files, <None> for anything
# else, such as reference-data scripts - SSDT rejects DML in a Build item), a <Folder> item
# for each new folder, and no items for files that no longer exist. SDK-style projects
# include **/*.sql by default: untouched.
function Update-SqlMigProject($Cfg, $Context, [switch]$Apply) {
  $result = @{ Changed = $false; Added = @(); Folders = @(); Removed = @(); Reason = $null }
  if (-not $Cfg.project -or -not (Test-Path -LiteralPath $Cfg.project)) { $result.Reason = 'no project configured'; return $result }
  $projPath = (Resolve-Path -LiteralPath $Cfg.project).ProviderPath
  $xml = New-Object System.Xml.XmlDocument
  $xml.PreserveWhitespace = $true
  $xml.Load($projPath)
  $rootEl = $xml.DocumentElement
  if ($rootEl.GetAttribute('Sdk') -or $xml.SelectSingleNode("//*[local-name()='Sdk']")) { $result.Reason = 'SDK-style project: files are included by default'; return $result }
  $ns = $rootEl.NamespaceURI
  $projDir = Split-Path $Cfg.project -Parent
  $prefix = if ($projDir) { (ConvertTo-SqlMigRelPath $projDir) + '/' } else { '' }
  if ($prefix -eq './') { $prefix = '' }
  $items = @($xml.SelectNodes("//*[(local-name()='Build' or local-name()='None')][@Include]"))
  $folders = @($xml.SelectNodes("//*[local-name()='Folder'][@Include]") | ForEach-Object { $_.GetAttribute('Include').TrimEnd('\') })
  $toAdd = @(); $folderAdd = @()
  foreach ($k in $Context.changes.Keys) {
    $c = $Context.changes[$k]
    if ($c.Status -eq 'D' -or $c.Status -eq 'M') { continue }
    $f = [string]$c.File
    if ($prefix -and -not $f.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $rel = $f.Substring($prefix.Length).Replace('/', '\')
    $covered = @($items | Where-Object { $inc = $_.GetAttribute('Include'); if ($inc -match '[*?]') { Test-SqlMigMsbuildWildcard $inc $rel } else { $inc -ieq $rel } }).Count -gt 0
    $folder = (Get-SqlMigPathParts $f).Folder
    $itemKind = if ($folder -and ($script:ObjectFolders -contains $folder -or $folder -eq 'Security' -or $folder -eq 'Stored Procedures')) { 'Build' } else { 'None' }
    if (-not $covered) { $toAdd += [pscustomobject]@{ Kind = $itemKind; Include = $rel } }
    $dir = Split-Path $rel -Parent
    while ($dir) {
      if ($folders -notcontains $dir -and $folderAdd -notcontains $dir) { $folderAdd += $dir }
      $dir = Split-Path $dir -Parent
    }
  }
  $stale = @()
  foreach ($n in @($xml.SelectNodes("//*[(local-name()='Build' or local-name()='None')][@Include]"))) {
    $inc = $n.GetAttribute('Include')
    if ($inc -match '[*?]' -or $inc -notmatch '(?i)\.sql$') { continue }
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $projPath -Parent) $inc.Replace('\', [IO.Path]::DirectorySeparatorChar)))) { $stale += $n }
  }
  $result.Added = @($toAdd | Sort-Object Kind, Include); $result.Folders = @($folderAdd | Sort-Object); $result.Removed = @($stale | ForEach-Object { $_.GetAttribute('Include') })
  if (-not $Apply -or ($toAdd.Count + $folderAdd.Count + $stale.Count) -eq 0) { return $result }

  # New nodes copy the file's own line breaks and indentation.
  $nl = if ([IO.File]::ReadAllText($projPath) -match "`r`n") { "`r`n" } else { "`n" }
  function Add-Item([string]$kind, [string]$include) {
    $group = $xml.SelectSingleNode("//*[local-name()='ItemGroup'][*[local-name()='$kind']]")
    if (-not $group) {
      $group = $xml.CreateElement('ItemGroup', $ns)
      $anchor = @($rootEl.ChildNodes | Where-Object { $_.NodeType -eq 'Element' }) | Select-Object -Last 1
      [void]$rootEl.InsertAfter($group, $anchor)
      [void]$rootEl.InsertAfter($xml.CreateWhitespace("$nl  "), $anchor)
      [void]$group.AppendChild($xml.CreateWhitespace("$nl  "))
    }
    $last = @($group.ChildNodes | Where-Object { $_.NodeType -eq 'Element' }) | Select-Object -Last 1
    $indent = "$nl    "
    if ($last -and $last.PreviousSibling -and $last.PreviousSibling.NodeType -in @('Whitespace', 'SignificantWhitespace')) { $indent = $last.PreviousSibling.Value }
    $el = $xml.CreateElement($kind, $ns); $el.SetAttribute('Include', $include)
    if ($last) { [void]$group.InsertAfter($el, $last); [void]$group.InsertAfter($xml.CreateWhitespace($indent), $last) }
    else { [void]$group.PrependChild($el); [void]$group.PrependChild($xml.CreateWhitespace($indent)) }
  }
  foreach ($d in $result.Folders) { Add-Item 'Folder' ($d + '\') }
  foreach ($a in $result.Added) { Add-Item $a.Kind $a.Include }
  foreach ($n in $stale) {
    $prev = $n.PreviousSibling
    [void]$n.ParentNode.RemoveChild($n)
    if ($prev -and $prev.NodeType -in @('Whitespace', 'SignificantWhitespace')) { [void]$prev.ParentNode.RemoveChild($prev) }
  }
  $settings = New-Object System.Xml.XmlWriterSettings
  $settings.Encoding = New-Object System.Text.UTF8Encoding ([bool]((Get-Content -LiteralPath $projPath -AsByteStream -TotalCount 3) -join ',' -eq '239,187,191'))
  $settings.OmitXmlDeclaration = -not ([IO.File]::ReadAllText($projPath).TrimStart().StartsWith('<?xml'))
  $settings.NewLineHandling = [System.Xml.NewLineHandling]::None
  $w = [System.Xml.XmlWriter]::Create($projPath, $settings)
  try { $xml.Save($w) } finally { $w.Dispose() }
  $result.Changed = $true
  $result
}

# ---------------------------------------------------------------------------------------
# prompt / apply: run the generation with any model, outside Claude Code
# ---------------------------------------------------------------------------------------

function Get-SqlMigPrompt($Cfg, $Context, [string]$SkillDir) {
  $skill = [IO.File]::ReadAllText((Join-Path $SkillDir 'SKILL.md'))
  $body = $skill -replace '(?s)^---.*?---\s*', ''
  # The interactive procedure is for Claude Code; a one-shot model call only generates.
  $body = [regex]::Replace($body, '(?s)<!-- interactive:begin -->.*?<!-- interactive:end -->\s*', '')
  $refs = foreach ($r in 'idempotent-patterns', 'column-modification', 'sql-standards', 'index-standards', 'security-constraints') { [IO.File]::ReadAllText((Join-Path $SkillDir "references/$r.md")) }
  $prompt = (@($body, (Format-SqlMigRepoConfig $Cfg)) + @($refs)) -join "`n`n"
  $changes = [ordered]@{}
  foreach ($k in $Context.changes.Keys) {
    $c = $Context.changes[$k]
    $o = [ordered]@{}
    foreach ($p in 'Status', 'File', 'OldFile', 'Content', 'Diff', 'IsNew', 'IsDeleted', 'WhitespaceOnly') { if (@($c.Keys) -contains $p) { $o[$p] = $c[$p] } }
    $changes[$k] = $o
  }
  $prompt = $prompt.Replace('{{BRANCH_NAME}}', $Context.branchSlug).Replace('{{DATABASE}}', $Context.database).Replace('{{DATE}}', $Context.date).Replace('{{NEXT_VERSION}}', $Context.nextVersion)
  $prompt.Replace('{{CHANGED_FILES_JSON}}', ($changes | ConvertTo-Json -Depth 10))
}

# Reads a <MIGRATION_RESPONSE> and returns the versioned script. The repeatable script is
# always rebuilt from source by `build`, so a model's <REPEATABLE_MIGRATION> is ignored.
function Read-SqlMigResponse([string]$Text) {
  if ($Text.IndexOf('</MIGRATION_RESPONSE>') -lt 0) { throw 'The response has no </MIGRATION_RESPONSE> - it is truncated or not a migration response; nothing was written' }
  $r = @{ Version = $null; VersionFileName = $null; Summary = $null }
  $s = $Text.IndexOf('<VERSION_MIGRATION>')
  if ($s -ge 0) {
    $e = $Text.IndexOf('</VERSION_MIGRATION>', $s)
    if ($e -lt 0) { throw '<VERSION_MIGRATION> is not closed' }
    $sec = $Text.Substring($s, $e - $s)
    $fn = [regex]::Match($sec, '<FILENAME>(.*?)</FILENAME>', 'Singleline')
    if ($fn.Success) { $r.VersionFileName = $fn.Groups[1].Value.Trim() }
    $cs = $sec.IndexOf('<CONTENT>'); $ce = $sec.LastIndexOf('</CONTENT>')
    if ($cs -lt 0 -or $ce -le $cs) { throw '<VERSION_MIGRATION> has no <CONTENT>' }
    $r.Version = $sec.Substring($cs + 9, $ce - $cs - 9).Trim()
  }
  $sm = [regex]::Match($Text, '<SUMMARY>(.*?)</SUMMARY>', 'Singleline')
  if ($sm.Success) { $r.Summary = $sm.Groups[1].Value.Trim() }
  $r
}
