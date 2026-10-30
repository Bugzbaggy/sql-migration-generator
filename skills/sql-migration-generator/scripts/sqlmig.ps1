<#
.SYNOPSIS
  The deterministic half of the sql-migration-generator skill: Flyway V__/R__ migration
  scripts from the changes on an SSDT database branch.

.DESCRIPTION
  Run it from anywhere inside the database repository (PowerShell 7+, git).

    init     Write migration.config.json from the .sqlproj.
             -Check reports drift between the config and the project; -RenderRepoConfig
             <file> writes the repository-configuration section a CI prompt needs.
    context  Work out what changed on this branch and where the scripts go, into the
             git directory (never committed). -RemoveExisting deletes this branch's
             previously generated scripts first (one with uncommitted edits is kept
             unless -Force).
    build    Finish the versioned script (V__) and build the repeatable one (R__)
             deterministically from the changed source files.
    check    Object-order check of this branch's scripts.
    project  Deploy-role grants for new schemas and the .sqlproj item list; -Apply writes.
    prompt   The one-shot generation prompt, to run the generator with any model.
    apply    Write the versioned script from a <MIGRATION_RESPONSE> (-ResponseFile).

  Exit codes: 0 success, 1 problems found or the command failed, 3 the check could not run
  (that is not a pass).

.EXAMPLE
  pwsh ./.claude/skills/sql-migration-generator/scripts/sqlmig.ps1 context -RemoveExisting
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0, Mandatory)]
  [ValidateSet('init', 'context', 'build', 'check', 'project', 'prompt', 'apply')]
  [string]$Command,
  [string]$Base,
  [string]$Branch,
  [string]$Date,
  [switch]$CommittedOnly,
  [switch]$RemoveExisting,
  [string]$Project,
  [switch]$Force,
  [switch]$Check,
  [string]$RenderRepoConfig,
  [switch]$Apply,
  [string]$ResponseFile,
  [string]$OutFile,
  [string]$Config = 'migration.config.json'
)

$ErrorActionPreference = 'Stop'
# git prints UTF-8; read it as UTF-8 whatever the console code page is.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

$skillDir = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'SqlMigration.Core.ps1')

# Paths given on the command line are relative to where it was typed.
$callerDir = (Get-Location).ProviderPath
function Resolve-CallerPath([string]$p) { if (-not $p) { return $p }; if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $callerDir $p } }
$ResponseFile = Resolve-CallerPath $ResponseFile
$OutFile = Resolve-CallerPath $OutFile
$RenderRepoConfig = Resolve-CallerPath $RenderRepoConfig

$top = (git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $top) { Write-SqlMigNote error 'Not inside a git repository'; exit 1 }
Push-Location -LiteralPath $top

function Write-Utf8File([string]$Path, [string]$Text) {
  $dir = Split-Path $Path -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [IO.File]::WriteAllText((Join-Path (Get-Location).ProviderPath $Path), $Text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-BranchVersionScript($Cfg, $Ctx) {
  # The versioned script for this branch: the context's file name, or the one script of
  # this branch with another version or date (written before the context was refreshed).
  if (Test-Path -LiteralPath $Ctx.versionFile) { return $Ctx.versionFile }
  $v = @(Get-SqlMigBranchScripts $Cfg $Ctx.branchSlug | Where-Object { (Split-Path $_ -Leaf) -match '^V' })
  if ($v.Count -gt 1) { throw "More than one versioned script for this branch: $($v -join ', ') - keep one" }
  if ($v.Count -eq 1) { Write-SqlMigNote warning "Using $($v[0]) (the context expects $($Ctx.versionFile))"; return $v[0] }
  $null
}

$code = 0
try {
  switch ($Command) {
    'init' {
      if ($Check) {
        $cfg = Get-SqlMigConfig $Config
        $d = Test-SqlMigConfigDrift $cfg
        foreach ($e in $d.Errors) { Write-SqlMigNote error $e }
        foreach ($w in $d.Warnings) { Write-SqlMigNote warning $w }
        if ($d.Errors.Count) { $code = 1 } elseif (-not $d.Warnings.Count) { Write-Host "$Config matches the project." }
      } elseif ($RenderRepoConfig) {
        $cfg = Get-SqlMigConfig $Config
        [IO.File]::WriteAllText($RenderRepoConfig, (Format-SqlMigRepoConfig $cfg), (New-Object System.Text.UTF8Encoding $false))
        Write-Host "Wrote $RenderRepoConfig"
      } else {
        $cfg = Initialize-SqlMigConfig -Project $Project -Path $Config -Force:$Force
        Write-Host "Wrote $Config :"
        Get-Content -LiteralPath $Config | ForEach-Object { Write-Host "  $_" }
        $full = Get-SqlMigConfig $Config
        Write-Host "Schemas found: $((Get-SqlMigSchemaDirs $full) -join ', ')"
        Write-Host 'Check database, ciRole and every sqlcmdVariables value before generating: a wrong name produces wrong scripts.'
      }
    }

    'context' {
      $cfg = Get-SqlMigConfig $Config
      $ctx = New-SqlMigContext $cfg -Base $Base -Branch $Branch -Date $Date -CommittedOnly:$CommittedOnly
      if ($RemoveExisting -and $ctx.existingScripts.Count) {
        $r = Remove-SqlMigBranchScripts $ctx.existingScripts -Force:$Force
        foreach ($p in $r.Removed) { Write-Host "Removed old script $p" }
        foreach ($p in $r.Kept) { Write-SqlMigNote warning "Kept $p - it has uncommitted edits (use -Force to remove it anyway)" }
        $ctx.existingScripts = @($r.Kept)
      }
      $path = Save-SqlMigContext $ctx
      Write-Host "Branch $($ctx.branch) vs $($ctx.baseRef) (merge base $($ctx.mergeBase.Substring(0, 10)))$(if ($ctx.committedOnly) { ', committed changes only' } else { ', including uncommitted changes' })"
      if ($ctx.summary.Count -eq 0) { Write-Host "No .sql changes under $($cfg.sourceRoot)/ - nothing to generate." }
      foreach ($s in $ctx.summary) { Write-Host ('  {0,-5} {1,-11} {2}{3}' -f $s.Status, $s.Kind, $s.File, $(if ($s.WhitespaceOnly) { '  (whitespace only - skip)' } else { '' })) }
      Write-Host "Versioned script : $($ctx.versionFile)$(if (-not $ctx.versionCandidates.Count) { '  (probably not needed: no structure changes)' })"
      Write-Host "Repeatable script: $($ctx.repeatableFile)"
      foreach ($n in $ctx.versionNotes) { Write-SqlMigNote warning $n }
      foreach ($p in $ctx.existingScripts) { Write-SqlMigNote warning "This branch already has $p - re-run with -RemoveExisting to regenerate" }
      Write-Host "Context: $path"
    }

    'build' {
      $cfg = Get-SqlMigConfig $Config
      $ctx = Read-SqlMigContext
      $vPath = Get-BranchVersionScript $cfg $ctx
      $vText = if ($vPath) { [IO.File]::ReadAllText((Resolve-Path -LiteralPath $vPath).ProviderPath) } else { $null }
      $res = Build-SqlMigRepeatable $cfg $ctx $vText
      $v = $res.VersionContent
      if ($v) {
        $removed = 0
        $v = Remove-SqlMigObjectGrants $v ([ref]$removed)
        if ($removed) { Write-Host "Moved $removed object-level grant batch(es) out of the versioned script (they belong in the repeatable one)" }
      }
      $unmapped = @()
      if ($v) { $cv = Convert-SqlMigVariables $v $cfg; $v = $cv.Text; $unmapped += $cv.Unmapped }
      $r = $res.Content
      if ($r) { $cr = Convert-SqlMigVariables $r $cfg; $r = $cr.Text; $unmapped += $cr.Unmapped }
      if ($v) { Write-Utf8File $vPath ((ConvertTo-SqlMigLineEndings $v $cfg.lineEndings).TrimEnd() + $(if ($cfg.lineEndings -eq 'crlf') { "`r`n" } else { "`n" })); Write-Host "Versioned script : $vPath" }
      elseif ($vPath) { Remove-Item -LiteralPath $vPath -Force; Write-Host "Removed $vPath - nothing substantive was left in it" }
      else { Write-Host 'Versioned script : none' }
      if ($r) {
        Write-Utf8File $ctx.repeatableFile ((ConvertTo-SqlMigLineEndings $r $cfg.lineEndings) + $(if ($cfg.lineEndings -eq 'crlf') { "`r`n" } else { "`n" }))
        Write-Host "Repeatable script: $($ctx.repeatableFile) ($($res.Objects) part(s))"
        Write-Host '  Emit order:'; foreach ($o in $res.Order) { Write-Host "    $o" }
        if ($res.Edges.Count) { Write-Host '  Dependencies:'; foreach ($e in $res.Edges) { Write-Host "    $e" } }
      } else {
        if (Test-Path -LiteralPath $ctx.repeatableFile) { Remove-Item -LiteralPath $ctx.repeatableFile -Force; Write-Host "Removed $($ctx.repeatableFile) - nothing repeatable changed" }
        else { Write-Host 'Repeatable script: none (no views, procedures, functions, triggers or grants changed)' }
      }
      foreach ($u in ($unmapped | Select-Object -Unique)) { Write-SqlMigNote error "`$($u) has no entry in sqlcmdVariables - add it to $Config and run build again"; $code = 1 }
    }

    'check' {
      $cfg = Get-SqlMigConfig $Config
      $ctx = Read-SqlMigContext
      $vPath = Get-BranchVersionScript $cfg $ctx
      $rPath = if (Test-Path -LiteralPath $ctx.repeatableFile) { $ctx.repeatableFile } else { $null }
      if (-not $vPath -and -not $rPath) { Write-Host 'No scripts for this branch - nothing to check.'; break }
      $vText = if ($vPath) { [IO.File]::ReadAllText((Resolve-Path -LiteralPath $vPath).ProviderPath) } else { '' }
      $rText = if ($rPath) { [IO.File]::ReadAllText((Resolve-Path -LiteralPath $rPath).ProviderPath) } else { '' }
      $vName = if ($vPath) { Split-Path $vPath -Leaf } else { '' }
      $rName = if ($rPath) { Split-Path $rPath -Leaf } else { '' }
      try { $res = Test-SqlMigOrder $cfg $ctx $vText $rText $vName $rName }
      catch {
        Write-SqlMigNote warning "The object-order check could not run: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber)) - the scripts are NOT verified"
        $code = 3; break
      }
      foreach ($w in $res.Warnings) { Write-SqlMigNote warning $w }
      foreach ($e in $res.Errors) { Write-SqlMigNote error $e }
      if ($res.Errors.Count) { Write-Host "Object-order check FAILED - $($res.Errors.Count) problem(s): the scripts would fail to deploy in this order"; $code = 1 }
      else { Write-Host "Object-order check passed ($(@($vPath, $rPath | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))" }
    }

    'project' {
      $cfg = Get-SqlMigConfig $Config
      $ctx = Read-SqlMigContext
      $role = Update-SqlMigRoleFile $cfg -Apply:$Apply
      if ($role.Reason) { Write-Host "Deploy-role grants: $($role.Reason)" }
      else { Write-Host "Deploy-role grants: $(if ($Apply) { 'added' } else { 'would add' }) ALTER, SELECT, INSERT, UPDATE, DELETE, EXECUTE, REFERENCES on $($role.Schemas -join ', ') to $($cfg.ciRole) in $($cfg.ciRoleFile)" }
      $p = Update-SqlMigProject $cfg $ctx -Apply:$Apply
      if ($p.Reason) { Write-Host "Project items: $($p.Reason)" }
      else {
        $verb = if ($Apply) { '' } else { 'would ' }
        foreach ($f in $p.Folders) { Write-Host "  ${verb}add  <Folder Include=`"$f\`" />" }
        foreach ($a in $p.Added) { Write-Host "  ${verb}add  <$($a.Kind) Include=`"$($a.Include)`" />" }
        foreach ($x in $p.Removed) { Write-Host "  ${verb}remove $x (the file no longer exists)" }
        if (-not ($p.Folders.Count + $p.Added.Count + $p.Removed.Count)) { Write-Host "Project items: $($cfg.project) already lists every file" }
      }
      if (-not $Apply -and ($role.Schemas.Count + $p.Folders.Count + $p.Added.Count + $p.Removed.Count)) { Write-Host 'Dry run - re-run with -Apply to write these changes.' }
    }

    'prompt' {
      $cfg = Get-SqlMigConfig $Config
      $ctx = Read-SqlMigContext
      $text = Get-SqlMigPrompt $cfg $ctx $skillDir
      $out = if ($OutFile) { $OutFile } else { Join-Path (Get-SqlMigWorkDir) 'prompt.md' }
      [IO.File]::WriteAllText($out, $text, (New-Object System.Text.UTF8Encoding $false))
      Write-Host "Prompt: $out ($([Math]::Round($text.Length / 1KB)) KB). Send it as one user message; save the reply and run: sqlmig.ps1 apply -ResponseFile <reply>"
    }

    'apply' {
      if (-not $ResponseFile -or -not (Test-Path -LiteralPath $ResponseFile)) { throw 'Pass -ResponseFile <file with the model''s <MIGRATION_RESPONSE>>' }
      $cfg = Get-SqlMigConfig $Config
      $ctx = Read-SqlMigContext
      $resp = Read-SqlMigResponse ([IO.File]::ReadAllText($ResponseFile))
      if ($resp.Version) {
        $leaf = Split-Path $ctx.versionFile -Leaf
        if ($resp.VersionFileName -and $resp.VersionFileName -ne $leaf) { Write-SqlMigNote warning "The response names $($resp.VersionFileName); writing $leaf, the name from the context" }
        Write-Utf8File $ctx.versionFile $resp.Version
        Write-Host "Versioned script: $($ctx.versionFile)"
      } else { Write-Host 'The response has no versioned migration.' }
      if ($resp.Summary) { Write-Host "Summary: $($resp.Summary)" }
      Write-Host 'Next: sqlmig.ps1 build, then sqlmig.ps1 check'
    }
  }
} catch {
  Write-SqlMigNote error $_.Exception.Message
  $code = 1
} finally {
  Pop-Location
}
exit $code
