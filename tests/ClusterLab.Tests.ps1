Import-Module "$PSScriptRoot\..\modules\ClusterLab.psm1" -Force
$module = Get-Module ClusterLab
$configuration = [IO.File]::ReadAllText("$PSScriptRoot\..\config\lab.psd1")

Describe 'Lab configuration boundaries' {
    It 'accepts the four-machine isolated topology' {
        $c = & $module { param($path) Get-LabConfig $path } "$PSScriptRoot\..\config\lab.psd1"
        $c.ManagementNetwork | Should Be '192.168.241.0'
        $c.PrivateNetwork | Should Be '192.168.242.0'
    }

    It 'rejects a broad disposable storage root' {
        $path = Join-Path $TestDrive 'unsafe.psd1'
        $configuration.Replace('C:\vm\labs\wfclab', 'C:\') | Set-Content -LiteralPath $path
        { & $module { param($p) Get-LabConfig $p } $path } | Should Throw
    }

    It 'rejects duplicate guest addresses' {
        $path = Join-Path $TestDrive 'duplicate.psd1'
        $configuration.Replace('192.168.241.12', '192.168.241.11') | Set-Content -LiteralPath $path
        { & $module { param($p) Get-LabConfig $p } $path } | Should Throw
    }

    It 'rejects a base image inside disposable storage' {
        $path = Join-Path $TestDrive 'parent.psd1'
        $configuration.Replace('C:\vm\images\ws2025\', 'C:\vm\labs\wfclab\') | Set-Content -LiteralPath $path
        { & $module { param($p) Get-LabConfig $p } $path } | Should Throw
    }

    It 'rejects shared management and private networks' {
        $path = Join-Path $TestDrive 'networks.psd1'
        $configuration.Replace('192.168.242.', '192.168.241.') | Set-Content -LiteralPath $path
        { & $module { param($p) Get-LabConfig $p } $path } | Should Throw
    }
}

Describe 'Unattended provisioning' {
    It 'escapes password XML without changing the credential' {
        $password = 'Ab<&1!"test'
        [xml]$xml = & $module { param($p) New-UnattendContent 'Node-A' 'labadmin' $p } $password
        $values = $xml.GetElementsByTagName('Value')
        $values.Count | Should Be 2
        $values[0].InnerText | Should Be $password
        $values[1].InnerText | Should Be $password
    }

    It 'answers language and keyboard selection during OOBE' {
        [xml]$xml = & $module { New-UnattendContent 'Lab-DC' 'labadmin' 'Ab1!example' }
        $ns = New-Object Xml.XmlNamespaceManager $xml.NameTable
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $international = $xml.SelectSingleNode("//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-International-Core']", $ns)
        $international.InputLocale | Should Be '0409:00000409'
        $international.SystemLocale | Should Be 'en-US'
        $international.UILanguage | Should Be 'en-US'
        $international.UserLocale | Should Be 'en-US'
    }
}
