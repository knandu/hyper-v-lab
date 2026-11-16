[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [switch]$Worker
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$r = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
$resultPath = "$RequestPath.result"
try {
    $result = switch ($r.Action) {
        'Forest' {
            $feature = Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
            if (-not $feature.Success) { throw 'AD DS installation failed.' }
            Install-ADDSForest -DomainName $r.Domain -DomainNetbiosName $r.NetBIOS -InstallDns `
                -SafeModeAdministratorPassword (ConvertTo-SecureString $r.Password -AsPlainText -Force) `
                -NoRebootOnCompletion -Force | Out-Null
            @{ Reboot = $true }
        }
        'DomainReady' {
            Import-Module ActiveDirectory
            $domain = Get-ADDomain -Identity $r.Domain
            Add-ADGroupMember -Identity 'Domain Admins' -Members $r.Administrator
            Set-ADUser -Identity $r.Administrator -PasswordNeverExpires $true
            $forwarders = @((Get-DnsServerForwarder).IPAddress | Where-Object { $_ })
            if ($forwarders.Count) { Remove-DnsServerForwarder -IPAddress $forwarders -Force }
            Set-DnsServerForwarder -UseRootHint $false
            @{ Domain = $domain.DNSRoot }
        }
        'Join' {
            $feature = Install-WindowsFeature Failover-Clustering -IncludeManagementTools
            if (-not $feature.Success) { throw 'Failover-Clustering installation failed.' }
            $credential = New-Object PSCredential "$($r.NetBIOS)\$($r.Administrator)", (ConvertTo-SecureString $r.Password -AsPlainText -Force)
            Add-Computer -DomainName $r.Domain -Credential $credential -Force
            @{ Reboot = $true }
        }
        'Cluster' {
            if (-not $Worker) {
                # SSH key logons do not carry delegable domain credentials.
                $taskName = 'ClusterLab-Provision'
                $argument = "-NoProfile -ExecutionPolicy Bypass -File C:\Lab\Guest.ps1 -RequestPath `"$RequestPath`" -Worker"
                $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
                $settings = New-ScheduledTaskSettingsSet -Compatibility Win7 -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
                $registered = $false
                try {
                    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Settings $settings `
                        -User "$($r.NetBIOS)\$($r.Administrator)" -Password $r.Password -RunLevel Highest -Force | Out-Null
                    $registered = $true
                    $started = (Get-Date).AddSeconds(-1)
                    Start-ScheduledTask -TaskName $taskName
                    $deadline = (Get-Date).AddMinutes(20)
                    while (-not (Test-Path -LiteralPath $resultPath)) {
                        if ((Get-Date) -gt $deadline) { throw 'Cluster provisioning task timed out.' }
                        $task = Get-ScheduledTask -TaskName $taskName
                        $info = Get-ScheduledTaskInfo -TaskName $taskName
                        if ($task.State -eq 'Ready' -and $info.LastRunTime -ge $started -and $info.LastTaskResult -ne 0) {
                            throw "Cluster provisioning task exited with code $($info.LastTaskResult) without a result."
                        }
                        Start-Sleep -Seconds 3
                    }
                    $taskResult = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
                    if (-not $taskResult.Success) { throw $taskResult.Error }
                    $taskResult.Data
                }
                finally {
                    if ($registered) {
                        $task = Get-ScheduledTask -TaskName $taskName
                        if ($task.State -in 'Running','Queued') { Stop-ScheduledTask -TaskName $taskName }
                        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                    }
                }
            }
            else {
                Import-Module FailoverClusters
                $report = 'C:\Lab\ClusterValidation'
                Test-Cluster -Node $r.Nodes -Ignore Storage -ReportName $report -WarningVariable validationWarnings | Out-Null
                $validationFile = Get-ChildItem 'C:\Windows\Cluster\Reports' -Filter 'Validation Data*.xml' |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if (-not $validationFile) { throw 'Cluster validation did not produce an XML report.' }
                [xml]$validation = Get-Content -LiteralPath $validationFile.FullName -Raw
                $failures = @($validation.SelectNodes('//Channel') | Where-Object { $_.Result.Value -in 'Fail','Failed','Error' })
                if ($failures.Count) { throw "Cluster validation failed. Inspect $($validationFile.FullName)." }
                $cluster = New-Cluster -Name $r.ClusterName -Node $r.Nodes -StaticAddress $r.ClusterAddress `
                    -IgnoreNetwork "$($r.PrivateNetwork)/24" -NoStorage
                foreach ($network in Get-ClusterNetwork) {
                    if ($network.Address -eq $r.ManagementNetwork) {
                        $network.Name = 'Management'
                        $network.Role = 3
                    }
                    elseif ($network.Address -eq $r.PrivateNetwork) {
                        $network.Name = 'Cluster-private'
                        $network.Role = 1
                    }
                    else { throw "Unexpected cluster network: $($network.Address)" }
                }
                Set-ClusterQuorum -NodeMajority | Out-Null
                @{ Name = $cluster.Name; ValidationReport = "$report.htm"; Warnings = @($validationWarnings | ForEach-Object { "$_" }) }
            }
        }
        'Health' {
            $computer = Get-CimInstance Win32_ComputerSystem
            $management = @(Get-NetAdapter | Where-Object { ($_.MacAddress -replace '-','') -eq $r.ManagementMAC })
            if ($management.Count -ne 1) { throw 'Management NIC identity mismatch.' }
            $managementIP = @(Get-NetIPAddress -InterfaceIndex $management[0].ifIndex -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -eq $r.Address -and $_.PrefixLength -eq $r.PrefixLength })
            if ($managementIP.Count -ne 1) { throw 'Management addressing mismatch.' }
            $dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $management[0].ifIndex -AddressFamily IPv4).ServerAddresses)
            $allowedDNS = @($r.DCAddress)
            if ($r.Role -eq 'DC') { $allowedDNS += '127.0.0.1' }
            if (-not $dnsServers.Count -or @($dnsServers | Where-Object { $_ -notin $allowedDNS }).Count) {
                throw 'Management DNS must point only to the lab DC (or its own loopback on the DC).'
            }
            $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
            $ipv6Routes = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue)
            if ($routes.Count -or $ipv6Routes.Count) { throw 'Guest has a default route.' }
            $dns = @(Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$($r.Domain)" -Type SRV -Server $r.DCAddress -DnsOnly)
            if (-not $dns.Count) { throw 'AD DNS SRV record missing.' }
            if ($computer.Domain -ne $r.Domain) { throw "Unexpected domain: $($computer.Domain)" }
            if ($r.Role -eq 'DC') {
                Import-Module ActiveDirectory
                if ((Get-ADDomain).DNSRoot -ne $r.Domain) { throw 'Domain controller is not ready.' }
                if (@(Get-Service NTDS,DNS,Netlogon | Where-Object Status -ne Running).Count) { throw 'AD/DNS service is stopped.' }
            }
            else {
                if (-not (Test-ComputerSecureChannel)) { throw 'Domain secure channel failed.' }
                $private = @(Get-NetAdapter | Where-Object { ($_.MacAddress -replace '-','') -eq $r.PrivateMAC })
                if ($private.Count -ne 1) { throw 'Private NIC identity mismatch.' }
                $privateIP = @(Get-NetIPAddress -InterfaceIndex $private[0].ifIndex -AddressFamily IPv4 |
                    Where-Object { $_.IPAddress -eq $r.PrivateAddress -and $_.PrefixLength -eq $r.PrefixLength })
                if ($privateIP.Count -ne 1) { throw 'Private addressing mismatch.' }
                if ((Get-DnsClient -InterfaceIndex $private[0].ifIndex).RegisterThisConnectionsAddress) { throw 'Private NIC registers DNS.' }
                if ((Get-Service ClusSvc).Status -ne 'Running') { throw 'Cluster service is stopped.' }
            }
            @{ Computer = $env:COMPUTERNAME; Domain = $computer.Domain; DNS = $true; NoDefaultRoute = $true }
        }
        'ClusterHealth' {
            Import-Module FailoverClusters
            $nodes = @(Get-ClusterNode)
            if ($nodes.Count -ne 3 -or @($nodes | Where-Object State -ne Up).Count) { throw 'Expected three Up cluster nodes.' }
            if (@(Compare-Object @($r.Nodes | Sort-Object) @($nodes.Name | Sort-Object)).Count) { throw 'Unexpected cluster membership.' }
            $resources = @(Get-ClusterResource)
            if (@($resources | Where-Object State -ne Online).Count) { throw 'A core cluster resource is offline.' }
            $networks = @(Get-ClusterNetwork)
            if ($networks.Count -ne 2) { throw 'Expected two cluster networks.' }
            if ((Get-ClusterNetwork -Name 'Management').Role -ne 3 -or (Get-ClusterNetwork -Name 'Cluster-private').Role -ne 1) {
                throw 'Cluster network roles are incorrect.'
            }
            if ((Get-Cluster).Name -ne $r.ClusterName) { throw 'Unexpected cluster name.' }
            $address = (Get-ClusterResource -Name 'Cluster IP Address' | Get-ClusterParameter -Name Address).Value
            if ($address -ne $r.ClusterAddress) { throw 'Cluster management address mismatch.' }
            @{ Name = (Get-Cluster).Name; Nodes = @($nodes.Name); Owner = (Get-ClusterGroup -Name 'Cluster Group').OwnerNode.Name }
        }
        'Failover' {
            Import-Module FailoverClusters
            $original = (Get-ClusterGroup -Name 'Cluster Group').OwnerNode.Name
            $target = @(Get-ClusterNode | Where-Object Name -ne $original)[0].Name
            Move-ClusterGroup -Name 'Cluster Group' -Node $target -Wait 120 | Out-Null
            if ((Get-ClusterGroup -Name 'Cluster Group').OwnerNode.Name -ne $target) { throw 'Cluster group did not move.' }
            Move-ClusterGroup -Name 'Cluster Group' -Node $original -Wait 120 | Out-Null
            @{ From = $original; To = $target; Returned = $true }
        }
        default { throw "Unknown guest action: $($r.Action)" }
    }
    $response = @{ Success = $true; Data = $result } | ConvertTo-Json -Depth 8 -Compress
    if ($Worker) {
        $response | Set-Content -LiteralPath "$resultPath.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$resultPath.tmp" -Destination $resultPath -Force
    }
    else { Write-Output $response }
}
catch {
    $response = @{ Success = $false; Error = "$($_.Exception.Message) [$($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)]" } | ConvertTo-Json -Compress
    if ($Worker) {
        $response | Set-Content -LiteralPath "$resultPath.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$resultPath.tmp" -Destination $resultPath -Force
    }
    else { Write-Output $response }
    exit 1
}
