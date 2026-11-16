[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([string]$ConfigPath = "$PSScriptRoot\..\config\lab.psd1")
Import-Module "$PSScriptRoot\..\modules\ClusterLab.psm1" -Force
if ($PSCmdlet.ShouldProcess($ConfigPath, 'Destroy and rebuild all lab VMs and identities')) {
    Invoke-Lab -Action Reset -ConfigPath $ConfigPath
}
