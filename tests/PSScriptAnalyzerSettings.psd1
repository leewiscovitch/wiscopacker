# PSScriptAnalyzer for tests/run. The scripts run in Windows PowerShell 5.1 (what Windows ships), so syntax
# that only PowerShell 7 knows is an error here, as is anything the parser rejects.
@{
  Severity = @("ParseError", "Error", "Warning")
  Rules    = @{
    PSUseCompatibleSyntax = @{
      Enable         = $true
      TargetVersions = @("5.1")
    }
  }
}
