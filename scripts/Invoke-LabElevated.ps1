[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('New','Start','Stop','Reset','Test','Remove')][string]$Action,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
$log = "$ResultPath.log"
Start-Transcript -Path $log -Force | Out-Null
try {
    Import-Module "$PSScriptRoot\..\modules\ClusterLab.psm1" -Force
    Invoke-Lab -Action $Action -ConfigPath $ConfigPath
    @{ Success = $true; Log = $log } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath
}
catch {
    Write-Host ($_ | Out-String)
    @{ Success = $false; Error = $_.Exception.Message; Log = $log } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
