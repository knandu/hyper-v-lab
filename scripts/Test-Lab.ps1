[CmdletBinding()]
param([string]$ConfigPath = "$PSScriptRoot\..\config\lab.psd1")
Import-Module "$PSScriptRoot\..\modules\ClusterLab.psm1" -Force
Invoke-Lab -Action Test -ConfigPath $ConfigPath
