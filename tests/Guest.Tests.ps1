$guestScript = "$PSScriptRoot\..\modules\Guest.ps1"

Describe 'Domain DNS finalization' {
    function Get-ADDomain { param($Identity) }
    function Add-ADGroupMember { param($Identity, $Members) }
    function Set-ADUser { param($Identity, $PasswordNeverExpires) }
    function Get-DnsServerForwarder {}
    function Remove-DnsServerForwarder { param($IPAddress, [switch]$Force) }
    function Set-DnsServerForwarder { param($UseRootHint) }

    Mock Import-Module {}
    Mock Get-ADDomain { [pscustomobject]@{ DNSRoot = 'wfclab.test' } }
    Mock Add-ADGroupMember {}
    Mock Set-ADUser {}
    Mock Get-DnsServerForwarder { [pscustomobject]@{ IPAddress = $null } }
    Mock Remove-DnsServerForwarder {}
    Mock Set-DnsServerForwarder {}

    It 'does not try to remove a null forwarder from an isolated DC' {
        $request = Join-Path $TestDrive 'domain.json'
        @{ Action = 'DomainReady'; Domain = 'wfclab.test'; Administrator = 'labadmin' } |
            ConvertTo-Json | Set-Content -LiteralPath $request
        $response = (& $guestScript -RequestPath $request) | ConvertFrom-Json
        $response.Success | Should Be $true
        $response.Data.Domain | Should Be 'wfclab.test'
        Assert-MockCalled Remove-DnsServerForwarder -Times 0 -Exactly
        Assert-MockCalled Set-DnsServerForwarder -Times 1 -Exactly -ParameterFilter { $UseRootHint -eq $false }
    }

}

Describe 'Cluster provisioning network boundaries' {
    function Test-Cluster { param($Node, $Ignore, $ReportName) }
    function New-Cluster { param($Name, $Node, $StaticAddress, $IgnoreNetwork, [switch]$NoStorage) }
    function Get-ClusterNetwork { param($Cluster) }
    function Set-ClusterQuorum { param($Cluster, [switch]$NodeMajority) }

    Mock Import-Module {}
    Mock Test-Cluster {}
    Mock Get-ChildItem { Get-Item -LiteralPath (Join-Path $TestDrive 'validation.xml') } -ParameterFilter { $Path -eq 'C:\Windows\Cluster\Reports' }
    Mock New-Cluster { [pscustomobject]@{ Name = 'wfcluster' } }
    Mock Get-ClusterNetwork {
        @(
            [pscustomobject]@{ Name = 'Network 1'; Address = '192.168.241.0'; Role = 3 }
            [pscustomobject]@{ Name = 'Network 2'; Address = '192.168.242.0'; Role = 3 }
        )
    }
    Mock Set-ClusterQuorum {}

    It 'does not allocate a cluster-name address on the private network' {
        '<Report><Channel><Result><Value>Success</Value></Result></Channel></Report>' |
            Set-Content -LiteralPath (Join-Path $TestDrive 'validation.xml')
        $request = Join-Path $TestDrive 'cluster.json'
        @{
            Action = 'Cluster'; Nodes = @('Node-A','Node-B','Node-C')
            ClusterName = 'wfcluster'; ClusterAddress = '192.168.241.20'
            ManagementNetwork = '192.168.241.0'; PrivateNetwork = '192.168.242.0'
        } | ConvertTo-Json | Set-Content -LiteralPath $request
        & $guestScript -RequestPath $request -Worker
        $response = Get-Content -LiteralPath "$request.result" -Raw | ConvertFrom-Json
        $response.Success | Should Be $true
        Assert-MockCalled New-Cluster -Times 1 -Exactly -ParameterFilter {
            $IgnoreNetwork -eq '192.168.242.0/24' -and $StaticAddress -eq '192.168.241.20' -and $NoStorage
        }
    }

    It 'refuses cluster creation when validation reports a failed test' {
        '<Report><Channel><Result><Value>Fail</Value></Result></Channel></Report>' |
            Set-Content -LiteralPath (Join-Path $TestDrive 'validation.xml')
        $request = Join-Path $TestDrive 'failed-cluster.json'
        @{ Action = 'Cluster'; Nodes = @('Node-A','Node-B','Node-C') } |
            ConvertTo-Json | Set-Content -LiteralPath $request
        & $guestScript -RequestPath $request -Worker
        $response = Get-Content -LiteralPath "$request.result" -Raw | ConvertFrom-Json
        $response.Success | Should Be $false
        $response.Error | Should Match 'Cluster validation failed'
        Assert-MockCalled New-Cluster -Times 0 -Exactly -Scope It
    }
}
