[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([string]$ConfigPath = "$PSScriptRoot\..\config\lab.psd1")
Import-Module "$PSScriptRoot\..\modules\ClusterLab.psm1" -Force
if ($PSCmdlet.ShouldProcess($ConfigPath, 'Remove only the owned lab VMs, disks, switches and credentials')) {
    Invoke-Lab -Action Remove -ConfigPath $ConfigPath
}
