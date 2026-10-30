@{
  Severity     = @('Error', 'Warning')
  ExcludeRules = @(
    # A command-line tool: its output is for the console, not the pipeline.
    'PSAvoidUsingWriteHost',
    # A native command's exit code lives in $global:LASTEXITCODE; resetting it after an
    # expected non-zero git exit is the point.
    'PSAvoidGlobalVars',
    # The project/role updates are dry runs unless -Apply: that switch is the confirmation.
    'PSUseShouldProcessForStateChangingFunctions',
    # Get-SqlMigChanges, Get-TableTriggers ... return collections, and say so.
    'PSUseSingularNouns'
  )
}
