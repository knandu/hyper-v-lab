Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Repository = Split-Path $PSScriptRoot

function Get-LabConfig {
    param([string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $c = Import-PowerShellDataFile -LiteralPath $resolved
    foreach ($key in 'Name','Root','Image','ImageSHA256','Domain','NetBIOS','Administrator','ManagementSwitch','PrivateSwitch','HostAddress','PrefixLength','ClusterName','ClusterAddress','ProcessorCount','MemoryBytes','TimeoutSeconds','Machines') {
        if (-not $c.ContainsKey($key)) { throw "Missing configuration key: $key" }
    }
    if ($c.Name -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,19}$') { throw 'Invalid lab name.' }
    foreach ($name in @($c.ClusterName, $c.NetBIOS) + @($c.Machines.Name)) {
        if ($name -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,14}$') { throw "Invalid computer/NetBIOS name: $name" }
    }
    if ($c.Domain -notmatch '^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$') { throw 'Invalid domain name.' }
    if ($c.Administrator -notmatch '^[a-zA-Z][a-zA-Z0-9_-]+$') { throw 'Invalid administrator name.' }
    $root = [IO.Path]::GetFullPath($c.Root).TrimEnd('\')
    if (-not [IO.Path]::IsPathRooted($c.Root) -or $root.Split('\').Count -lt 4 -or (Split-Path $root -Leaf) -ne $c.Name) {
        throw 'Root must be an absolute lab-specific directory ending in the lab name, at least three directories below the drive root.'
    }
    if ($root.StartsWith($script:Repository, [StringComparison]::OrdinalIgnoreCase) -or
        $script:Repository.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) { throw 'Lab storage must be outside the repository.' }
    if ([IO.Path]::GetFullPath($c.Image).StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) { throw 'Base image must be outside disposable lab storage.' }
    if ($c.PrefixLength -ne 24) { throw 'This harness currently supports /24 networks only.' }
    if ($c.Machines.Count -ne 4 -or @($c.Machines | Where-Object Role -eq DC).Count -ne 1 -or
        @($c.Machines | Where-Object Role -eq Node).Count -ne 3) { throw 'Configure exactly one DC and three nodes.' }
    if (@($c.Machines.Name | Select-Object -Unique).Count -ne 4) { throw 'Machine names must be unique.' }
    if ($c.ManagementSwitch -eq $c.PrivateSwitch) { throw 'Switch names must be distinct.' }
    $addresses = @($c.HostAddress, $c.ClusterAddress) + @($c.Machines | ForEach-Object Address) + @($c.Machines | Where-Object Role -eq Node | ForEach-Object PrivateAddress)
    foreach ($address in $addresses) {
        $parsed = [Net.IPAddress]::Parse($address)
        if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsed.GetAddressBytes()[3] -in 0,255) { throw "Invalid host IPv4 address: $address" }
    }
    if (@($addresses | Select-Object -Unique).Count -ne $addresses.Count) { throw 'IP addresses must be unique.' }
    $management = ($c.HostAddress -split '\.')[0..2] -join '.'
    $private = (@($c.Machines | Where-Object Role -eq Node)[0].PrivateAddress -split '\.')[0..2] -join '.'
    if ($management -eq $private) { throw 'Management and private networks must differ.' }
    foreach ($address in @($c.ClusterAddress) + @($c.Machines | ForEach-Object Address)) {
        if (-not $address.StartsWith("$management.")) { throw 'Management addresses must share a subnet.' }
    }
    foreach ($machine in $c.Machines | Where-Object Role -eq Node) {
        if (-not $machine.PrivateAddress.StartsWith("$private.")) { throw 'Private addresses must share a subnet.' }
    }
    $macs = @($c.Machines.ManagementMAC) + @($c.Machines | Where-Object Role -eq Node | ForEach-Object PrivateMAC)
    if (@($macs | Where-Object { $_ -notmatch '^[0-9A-Fa-f]{12}$' }).Count -or
        @($macs | Select-Object -Unique).Count -ne 7) { throw 'Configure seven unique 12-digit MAC addresses.' }
    if ($c.MemoryBytes -lt 2GB -or $c.ProcessorCount -lt 1 -or $c.TimeoutSeconds -lt 60) { throw 'Invalid VM resource or timeout settings.' }
    $c.Root = $root
    $c.ConfigPath = $resolved
    $c.ManagementNetwork = "$management.0"
    $c.PrivateNetwork = "$private.0"
    return $c
}

function Save-LabState {
    param($Context)
    $path = Join-Path $Context.Config.Root 'state.json'
    $Context.State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}

function Get-LabContext {
    param($Config)
    $path = Join-Path $Config.Root 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Lab does not exist. Run New-Lab.ps1 first.' }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($state.Name -ne $Config.Name -or $state.Root -ne $Config.Root -or $state.Schema -ne 1) { throw 'Lab ownership/state mismatch.' }
    if ($state.ConfigHash -ne (Get-FileHash -LiteralPath $Config.ConfigPath -Algorithm SHA256).Hash) { throw 'Configuration changed. Restore it before operating on this lab; remove the lab before changing configuration.' }
    [pscustomobject]@{ Config = $Config; State = $state }
}

function Get-OwnedVM {
    param($Context, $Machine)
    $record = @($Context.State.Machines | Where-Object Name -eq $Machine.Name)
    if ($record.Count -ne 1 -or -not $record[0].Id) { throw "Missing VM ownership record: $($Machine.Name)" }
    $vm = Get-VM -Id ([guid]$record[0].Id)
    if ($vm.Name -ne "$($Context.Config.Name)-$($Machine.Name)" -or $vm.Notes -ne "ClusterLab:$($Context.State.Id)") {
        throw "VM ownership mismatch: $($Machine.Name)"
    }
    $vm
}

function Get-OwnedSwitch {
    param($Context, [string]$Kind)
    $record = $Context.State.Switches.$Kind
    if (-not $record.Id) { throw "Missing $Kind switch ownership record." }
    $switch = Get-VMSwitch -Id ([guid]$record.Id)
    if ($switch.Name -ne $record.Name -or $switch.Notes -ne "ClusterLab:$($Context.State.Id)") { throw 'Switch ownership mismatch.' }
    $switch
}

function New-UnattendContent {
    param([string]$ComputerName, [string]$Administrator, [string]$Password)
    $passwordXml = [Security.SecurityElement]::Escape($Password)
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$ComputerName</ComputerName><TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts>
        <AdministratorPassword><Value>$passwordXml</Value><PlainText>true</PlainText></AdministratorPassword>
        <LocalAccounts><LocalAccount xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" wcm:action="add">
          <Name>$Administrator</Name><Group>Administrators</Group>
          <Password><Value>$passwordXml</Value><PlainText>true</PlainText></Password>
        </LocalAccount></LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

function Wait-Direct {
    param($Context, $Machine)
    $credential = Import-Clixml -LiteralPath (Join-Path $Context.Config.Root 'credential.xml')
    $vm = Get-OwnedVM $Context $Machine
    $deadline = (Get-Date).AddSeconds($Context.Config.TimeoutSeconds)
    $lastError = ''
    do {
        $session = $null
        try {
            $session = New-PSSession -VMId $vm.Id -Credential $credential -ErrorAction Stop
            $complete = Invoke-Command -Session $session -ScriptBlock {
                $state = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
                $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
                $state.ImageState -eq 'IMAGE_STATE_COMPLETE' -and
                    $setup.OOBEInProgress -eq 0 -and $setup.SystemSetupInProgress -eq 0
            }
            if ($complete) { return $session }
            $lastError = 'Windows specialization/OOBE has not finished.'
        }
        catch {
            $lastError = $_.Exception.Message
        }
        if ($session) { Remove-PSSession $session }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "PowerShell Direct bootstrap timed out for $($Machine.Name): $lastError"
}

function Get-SSHArguments {
    param($Context)
    @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes',
        '-o','ConnectTimeout=10','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=4',
        '-o',("UserKnownHostsFile=" + (Join-Path $Context.Config.Root 'known_hosts')),
        '-i',(Join-Path $Context.Config.Root 'id_ed25519'))
}

function Invoke-SSH {
    param($Context, $Machine, [string]$Command, [switch]$Domain)
    $user = $Context.Config.Administrator
    if ($Domain) { $user = "$($Context.Config.NetBIOS)\$user" }
    $arguments = @(Get-SSHArguments $Context)
    $output = & ssh.exe @arguments -l $user $Machine.Address $Command 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SSH $($Machine.Name) failed ($LASTEXITCODE): $($output -join [Environment]::NewLine)" }
    $output -join [Environment]::NewLine
}

function Wait-SSH {
    param($Context, $Machine, [switch]$Domain)
    $deadline = (Get-Date).AddSeconds($Context.Config.TimeoutSeconds)
    $lastError = ''
    do {
        try {
            $null = Invoke-SSH $Context $Machine 'powershell.exe -NoProfile -Command "[Console]::WriteLine($env:COMPUTERNAME)"' -Domain:$Domain
            return
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 5
        }
    } while ((Get-Date) -lt $deadline)
    throw "SSH readiness timed out for $($Machine.Name): $lastError"
}

function Invoke-Guest {
    param($Context, $Machine, [string]$Action, [switch]$Domain)
    $c = $Context.Config
    $requestId = [guid]::NewGuid().ToString('N')
    $local = Join-Path $c.Root "$requestId.json"
    $remote = "C:\Lab\$requestId.json"
    $credential = Import-Clixml -LiteralPath (Join-Path $c.Root 'credential.xml')
    $request = @{
        Action = $Action; Domain = $c.Domain; NetBIOS = $c.NetBIOS
        Administrator = $c.Administrator; DCAddress = ($c.Machines | Where-Object Role -eq DC).Address
        Role = $Machine.Role; Nodes = @($c.Machines | Where-Object Role -eq Node | ForEach-Object Name)
        ClusterName = $c.ClusterName; ClusterAddress = $c.ClusterAddress
        ManagementNetwork = $c.ManagementNetwork; PrivateNetwork = $c.PrivateNetwork
        ManagementMAC = $Machine.ManagementMAC; PrivateMAC = $Machine.PrivateMAC
        Address = $Machine.Address; PrivateAddress = $Machine.PrivateAddress; PrefixLength = $c.PrefixLength
    }
    if ($Action -in 'Forest','Join','Cluster') { $request.Password = $credential.GetNetworkCredential().Password }
    $user = $c.Administrator
    if ($Domain) { $user = "$($c.NetBIOS)\$user" }
    try {
        $request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $local -Encoding UTF8
        $arguments = @(Get-SSHArguments $Context)
        $copyOutput = & scp.exe -O @arguments $local "${user}@$($Machine.Address):$remote" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "SCP failed: $($copyOutput -join [Environment]::NewLine)" }
        $raw = Invoke-SSH $Context $Machine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Lab\Guest.ps1 -RequestPath $remote" -Domain:$Domain
        $line = @($raw -split '\r?\n' | Where-Object { $_.StartsWith('{"') }) | Select-Object -Last 1
        if (-not $line) { throw "No guest response: $raw" }
        $response = $line | ConvertFrom-Json
        if (-not $response.Success) { throw "Guest $Action failed: $($response.Error)" }
        $response.Data
    }
    finally {
        Remove-Item -LiteralPath $local -Force -ErrorAction Stop
        $cleanup = "foreach (`$path in @('$remote','$remote.result')) { if (Test-Path -LiteralPath `$path) { Remove-Item -LiteralPath `$path -Force -ErrorAction Stop } }"
        $null = Invoke-SSH $Context $Machine "powershell.exe -NoProfile -Command `"$cleanup`"" -Domain:$Domain
    }
}

function Restart-LabGuest {
    param($Context, $Machine)
    $null = Invoke-SSH $Context $Machine 'shutdown.exe /r /t 2 /f'
    Start-Sleep -Seconds 15
    Wait-SSH $Context $Machine
}

function Initialize-Guest {
    param($Context, $Machine)
    Write-Host "Bootstrapping $($Machine.Name)..."
    $session = Wait-Direct $Context $Machine
    try {
        $publicKey = Get-Content -LiteralPath (Join-Path $Context.Config.Root 'id_ed25519.pub') -Raw
        $dc = ($Context.Config.Machines | Where-Object Role -eq DC).Address
        $key = Invoke-Command -Session $session -ArgumentList $Machine,$Context.Config.PrefixLength,$dc,$publicKey,$Context.Config.Administrator -ScriptBlock {
            param($machine, $prefix, $dns, $publicKey, $administrator)
            $ErrorActionPreference = 'Stop'
            $management = Get-NetAdapter | Where-Object { ($_.MacAddress -replace '-','') -eq $machine.ManagementMAC }
            if (-not $management) { throw 'Management NIC MAC not found.' }
            Rename-NetAdapter -Name $management.Name -NewName Management
            Set-NetIPInterface -InterfaceAlias Management -AddressFamily IPv4 -Dhcp Disabled
            Get-NetIPAddress -InterfaceAlias Management -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
            New-NetIPAddress -InterfaceAlias Management -IPAddress $machine.Address -PrefixLength $prefix | Out-Null
            Set-DnsClientServerAddress -InterfaceAlias Management -ServerAddresses $dns
            if ($machine.Role -eq 'Node') {
                $private = Get-NetAdapter | Where-Object { ($_.MacAddress -replace '-','') -eq $machine.PrivateMAC }
                if (-not $private) { throw 'Private NIC MAC not found.' }
                Rename-NetAdapter -Name $private.Name -NewName Cluster-private
                Set-NetIPInterface -InterfaceAlias Cluster-private -AddressFamily IPv4 -Dhcp Disabled
                Get-NetIPAddress -InterfaceAlias Cluster-private -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
                New-NetIPAddress -InterfaceAlias Cluster-private -IPAddress $machine.PrivateAddress -PrefixLength $prefix | Out-Null
                Set-DnsClient -InterfaceAlias Cluster-private -RegisterThisConnectionsAddress $false
                Set-DnsClientServerAddress -InterfaceAlias Cluster-private -ResetServerAddresses
            }
            Set-LocalUser -Name $administrator -PasswordNeverExpires $true
            New-Item -Path 'C:\Lab' -ItemType Directory -Force | Out-Null
            & icacls.exe 'C:\Lab' /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Failed to protect guest staging directory.' }
            if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw 'Base image must contain OpenSSH Server for offline provisioning.' }
            $sshPath = Join-Path $env:ProgramData 'ssh'
            New-Item -Path $sshPath -ItemType Directory -Force | Out-Null
            $authorized = Join-Path $sshPath 'administrators_authorized_keys'
            $publicKey.Trim() | Set-Content -LiteralPath $authorized -Encoding ASCII
            & icacls.exe $authorized /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Failed to protect authorized keys.' }
            @'
Port 22
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
Subsystem sftp sftp-server.exe
'@ | Set-Content -LiteralPath (Join-Path $sshPath 'sshd_config') -Encoding ASCII
            Set-Service sshd -StartupType Automatic
            Start-Service sshd
            if (-not (Get-NetFirewallRule -Name 'ClusterLab-SSH' -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name 'ClusterLab-SSH' -DisplayName 'ClusterLab SSH' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -RemoteAddress LocalSubnet | Out-Null
            }
            Get-ChildItem -LiteralPath 'C:\Windows\Panther' -Filter '*unattend*.xml' -Recurse -ErrorAction Stop | Remove-Item -Force
            Get-Content -LiteralPath (Join-Path $sshPath 'ssh_host_ed25519_key.pub') -Raw
        }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Guest.ps1') -Destination 'C:\Lab\Guest.ps1' -ToSession $session
        $knownHosts = Join-Path $Context.Config.Root 'known_hosts'
        "$($Machine.Address) $($key.Trim())" | Add-Content -LiteralPath $knownHosts -Encoding ASCII
    }
    finally { Remove-PSSession $session }
    Wait-SSH $Context $Machine
}

function New-LabMachine {
    param($Context, $Machine, [string]$Password)
    $c = $Context.Config
    $name = "$($c.Name)-$($Machine.Name)"
    $directory = Join-Path $c.Root $Machine.Name
    if (Test-Path -LiteralPath $directory) { throw "Unowned VM directory already exists: $directory" }
    New-Item -Path $directory -ItemType Directory | Out-Null
    $diskPath = Join-Path $directory 'os.vhdx'
    New-VHD -Path $diskPath -ParentPath $c.Image -Differencing | Out-Null
    $mounted = $false
    try {
        $disk = Mount-VHD -Path $diskPath -NoDriveLetter -Passthru | Get-Disk
        $mounted = $true
        $roots = @(Get-Partition -DiskNumber $disk.Number | ForEach-Object AccessPaths | Where-Object { $_ })
        $windows = @($roots | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'Windows\System32\ntoskrnl.exe') })
        if ($windows.Count -ne 1) { throw 'Expected exactly one Windows partition.' }
        $state = Get-Content -LiteralPath (Join-Path $windows[0] 'Windows\Setup\State\State.ini') -Raw
        if ($state -notmatch 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw 'Base image is not generalized and resealed to OOBE.' }
        $panther = Join-Path $windows[0] 'Windows\Panther'
        New-Item -Path $panther -ItemType Directory -Force | Out-Null
        New-UnattendContent $Machine.Name $c.Administrator $Password | Set-Content -LiteralPath (Join-Path $panther 'unattend.xml') -Encoding UTF8
    }
    finally { if ($mounted) { Dismount-VHD -Path $diskPath } }
    $vm = New-VM -Name $name -Generation 2 -MemoryStartupBytes $c.MemoryBytes -VHDPath $diskPath -Path $directory -SwitchName $c.ManagementSwitch
    $record = [pscustomobject]@{ Name = $Machine.Name; Id = $vm.Id.ToString(); Stage = 'Created' }
    $Context.State.Machines += $record
    Save-LabState $Context
    Set-VM -VM $vm -Notes "ClusterLab:$($Context.State.Id)" -ProcessorCount $c.ProcessorCount -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Set-VMNetworkAdapter -VMName $vm.Name -Name 'Network Adapter' -StaticMacAddress $Machine.ManagementMAC
    Rename-VMNetworkAdapter -VMName $vm.Name -Name 'Network Adapter' -NewName Management
    if ($Machine.Role -eq 'Node') {
        Add-VMNetworkAdapter -VMName $vm.Name -Name Cluster-private -SwitchName $c.PrivateSwitch -StaticMacAddress $Machine.PrivateMAC
    }
    Get-VMNetworkAdapter -VMName $vm.Name | Set-VMNetworkAdapter -DhcpGuard On -RouterGuard On -MacAddressSpoofing Off
    Start-VM -VM $vm | Out-Null
}

function New-LabEnvironment {
    param($Config)
    $c = $Config
    if (Test-Path -LiteralPath (Join-Path $c.Root 'state.json')) {
        $existing = Get-LabContext $c
        if ($existing.State.Stage -eq 'Ready') { Test-LabEnvironment $existing; return }
        throw 'A partial lab exists. Inspect logs, then use Reset-Lab.ps1 to rebuild it.'
    }
    if ((Get-FileHash -LiteralPath $c.Image -Algorithm SHA256).Hash -ne $c.ImageSHA256) { throw 'Base-image SHA256 mismatch.' }
    if ((Get-VHD -Path $c.Image).Attached) { throw 'Base image must not be attached.' }
    foreach ($switch in $c.ManagementSwitch,$c.PrivateSwitch) {
        if (Get-VMSwitch -Name $switch -ErrorAction SilentlyContinue) { throw "Switch name already in use: $switch" }
    }
    foreach ($machine in $c.Machines) {
        if (Get-VM -Name "$($c.Name)-$($machine.Name)" -ErrorAction SilentlyContinue) { throw "VM name already in use: $($machine.Name)" }
    }
    foreach ($network in $c.ManagementNetwork,$c.PrivateNetwork) {
        $prefix = ($network -split '\.')[0..2] -join '.'
        if (@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -Like "$prefix.*").Count) { throw "Host address overlaps lab network: $network" }
        if (@(Get-NetRoute -AddressFamily IPv4 | Where-Object DestinationPrefix -eq "$network/24").Count) { throw "Host route overlaps lab network: $network" }
    }
    if ((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB -lt 4 * $c.MemoryBytes + 4GB) { throw 'Insufficient free host memory for four fixed-memory VMs and host headroom.' }
    $context = [pscustomobject]@{ Config = $c; State = [pscustomobject]@{
        Schema = 1; Name = $c.Name; Root = $c.Root; Id = [guid]::NewGuid().ToString()
        ConfigHash = (Get-FileHash -LiteralPath $c.ConfigPath -Algorithm SHA256).Hash
        Stage = 'Creating'; Machines = @()
        Switches = [pscustomobject]@{
            Management = [pscustomobject]@{ Name = $c.ManagementSwitch; Id = '' }
            Private = [pscustomobject]@{ Name = $c.PrivateSwitch; Id = '' }
        }
    } }
    Save-LabState $context
    $random = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    $password = 'Aa1!' + [Convert]::ToBase64String($random)
    $credential = New-Object PSCredential $c.Administrator, (ConvertTo-SecureString $password -AsPlainText -Force)
    $credential | Export-Clixml -LiteralPath (Join-Path $c.Root 'credential.xml')
    $keyPath = Join-Path $c.Root 'id_ed25519'
    $keyArguments = '-q -t ed25519 -N "" -f "{0}"' -f $keyPath
    $keygen = Start-Process -FilePath (Get-Command ssh-keygen.exe).Source -ArgumentList $keyArguments -Wait -PassThru -NoNewWindow
    if ($keygen.ExitCode -ne 0) { throw 'SSH client key generation failed.' }
    foreach ($kind in 'Management','Private') {
        $type = if ($kind -eq 'Management') { 'Internal' } else { 'Private' }
        $switch = New-VMSwitch -Name $context.State.Switches.$kind.Name -SwitchType $type -Notes "ClusterLab:$($context.State.Id)"
        $context.State.Switches.$kind.Id = $switch.Id.ToString()
        Save-LabState $context
    }
    $alias = "vEthernet ($($c.ManagementSwitch))"
    New-NetIPAddress -InterfaceAlias $alias -IPAddress $c.HostAddress -PrefixLength $c.PrefixLength | Out-Null
    Set-NetIPInterface -InterfaceAlias $alias -Forwarding Disabled -WeakHostSend Disabled -WeakHostReceive Disabled
    Set-DnsClient -InterfaceAlias $alias -RegisterThisConnectionsAddress $false
    foreach ($machine in $c.Machines) { New-LabMachine $context $machine $password }
    foreach ($machine in $c.Machines) {
        Initialize-Guest $context $machine
        ($context.State.Machines | Where-Object Name -eq $machine.Name).Stage = 'SSH'
        Save-LabState $context
    }
    $dc = $c.Machines | Where-Object Role -eq DC
    Write-Host 'Creating isolated AD forest...'
    $null = Invoke-Guest $context $dc Forest
    Restart-LabGuest $context $dc
    $null = Invoke-Guest $context $dc DomainReady
    foreach ($machine in $c.Machines | Where-Object Role -eq Node) {
        Write-Host "Joining $($machine.Name)..."
        $null = Invoke-Guest $context $machine Join
        Restart-LabGuest $context $machine
        ($context.State.Machines | Where-Object Name -eq $machine.Name).Stage = 'Joined'
        Save-LabState $context
    }
    $first = @($c.Machines | Where-Object Role -eq Node)[0]
    Wait-SSH $context $first -Domain
    Write-Host 'Validating and creating the cluster...'
    $cluster = Invoke-Guest $context $first Cluster -Domain
    $manifest = [ordered]@{
        SchemaVersion = 1; LabId = $context.State.Id; Domain = $c.Domain
        Cluster = @{ Name = $c.ClusterName; Address = $c.ClusterAddress; Nodes = @($c.Machines | Where-Object Role -eq Node | ForEach-Object Name) }
        SSH = @{ User = "$($c.NetBIOS)\$($c.Administrator)"; PrivateKey = $keyPath; KnownHosts = (Join-Path $c.Root 'known_hosts') }
        Machines = @($c.Machines | ForEach-Object { @{ Name = $_.Name; Role = $_.Role; Address = $_.Address; PrivateAddress = $_.PrivateAddress } })
        Validation = $cluster
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $c.Root 'environment.json') -Encoding UTF8
    Test-LabEnvironment $context
    $failover = Invoke-Guest $context $first Failover -Domain
    $failover | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $c.Root 'failover.json')
    $context.State.Stage = 'Ready'
    Save-LabState $context
    Write-Host "Environment manifest: $($c.Root)\environment.json"
}

function Test-LabEnvironment {
    param($Context)
    $c = $Context.Config
    foreach ($machine in $c.Machines) {
        $vm = Get-OwnedVM $Context $machine
        if ($vm.State -ne 'Running') { throw "$($machine.Name) is not running." }
        $adapters = @(Get-VMNetworkAdapter -VM $vm)
        $expectedCount = if ($machine.Role -eq 'Node') { 2 } else { 1 }
        if ($adapters.Count -ne $expectedCount) { throw "Unexpected NIC count: $($vm.Name)" }
        foreach ($adapter in $adapters) {
            $expected = if ($adapter.Name -eq 'Management') { $Context.State.Switches.Management.Id } elseif ($adapter.Name -eq 'Cluster-private') { $Context.State.Switches.Private.Id } else { throw 'Unexpected NIC name.' }
            if ($adapter.SwitchId.ToString() -ne $expected) { throw 'Guest NIC connected to an unexpected switch.' }
        }
        $health = Invoke-Guest $Context $machine Health -Domain
        if ($health.Computer -ne $machine.Name) { throw 'SSH endpoint identity mismatch.' }
        Write-Host ("{0,-12} PASS" -f $machine.Name)
    }
    Write-Host 'AD/DNS       PASS'
    Write-Host 'Domain       PASS'
    Write-Host 'SSH          PASS'
    $first = @($c.Machines | Where-Object Role -eq Node)[0]
    $null = Invoke-Guest $Context $first ClusterHealth -Domain
    Write-Host 'Cluster      PASS'
    $management = Get-OwnedSwitch $Context Management
    $private = Get-OwnedSwitch $Context Private
    if ($management.SwitchType -ne 'Internal' -or $private.SwitchType -ne 'Private') { throw 'Switch isolation is incorrect.' }
    $alias = "vEthernet ($($c.ManagementSwitch))"
    if (@(Get-NetIPInterface -InterfaceAlias $alias | Where-Object Forwarding -ne Disabled).Count) { throw 'Host forwards lab traffic.' }
    if (@(Get-NetRoute -InterfaceAlias $alias | Where-Object DestinationPrefix -in '0.0.0.0/0','::/0').Count) { throw 'Lab host interface has a default route.' }
    $labSwitchIds = @($management.Id, $private.Id)
    $ownedIds = @($Context.State.Machines.Id)
    foreach ($vm in Get-VM) {
        if ($vm.Id.ToString() -notin $ownedIds -and @(Get-VMNetworkAdapter -VM $vm | Where-Object SwitchId -in $labSwitchIds).Count) { throw 'An unowned VM is attached to a lab switch.' }
    }
    Write-Host 'Isolation    PASS'
}

function Stop-LabEnvironment {
    param($Context)
    $machines = @($Context.Config.Machines | Sort-Object { $_.Role -eq 'DC' })
    foreach ($machine in $machines) {
        $vm = Get-OwnedVM $Context $machine
        if ($vm.State -ne 'Off') {
            Stop-VM -VM $vm
            if ((Get-VM -Id $vm.Id).State -ne 'Off') { throw "VM did not shut down: $($vm.Name)" }
        }
    }
}

function Remove-LabEnvironment {
    param($Context)
    $c = $Context.Config
    # Validate all recorded identities before deleting any resources.
    $vms = @()
    foreach ($record in $Context.State.Machines) {
        $machine = $c.Machines | Where-Object Name -eq $record.Name
        if (-not $machine) { throw 'Unknown machine in ownership state.' }
        $vms += Get-OwnedVM $Context $machine
    }
    $switches = @()
    foreach ($kind in 'Management','Private') {
        if ($Context.State.Switches.$kind.Id) { $switches += Get-OwnedSwitch $Context $kind }
    }
    $vmIds = @($vms | ForEach-Object Id)
    $switchIds = @($switches | ForEach-Object Id)
    foreach ($vm in Get-VM) {
        if ($vm.Id -notin $vmIds -and @(Get-VMNetworkAdapter -VM $vm | Where-Object SwitchId -in $switchIds).Count) { throw 'An unowned VM uses a lab switch; refusing removal.' }
    }
    foreach ($machine in $c.Machines) {
        $directory = Join-Path $c.Root $machine.Name
        if (Test-Path -LiteralPath $directory) {
            if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing to delete a redirected VM directory.' }
            foreach ($item in Get-ChildItem -LiteralPath $directory -Recurse -Force) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing to delete VM files containing reparse points.' }
            }
        }
    }
    foreach ($vm in $vms) {
        if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force }
        Remove-VM -VM $vm -Force
    }
    foreach ($switch in $switches) { Remove-VMSwitch -VMSwitch $switch -Force }
    foreach ($machine in $c.Machines) {
        $directory = Join-Path $c.Root $machine.Name
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
    foreach ($name in 'credential.xml','id_ed25519','id_ed25519.pub','known_hosts','environment.json','failover.json','state.json') {
        $path = Join-Path $c.Root $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Write-Host 'Owned lab resources removed; base image and logs preserved.'
}

function Invoke-Lab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('New','Start','Stop','Reset','Test','Remove')][string]$Action,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $c = Get-LabConfig $ConfigPath
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $elevated -or $PSVersionTable.PSEdition -ne 'Desktop') {
        $results = Join-Path $script:Repository '.lab'
        New-Item -Path $results -ItemType Directory -Force | Out-Null
        $resultPath = Join-Path $results ("$Action-" + [guid]::NewGuid().ToString('N') + '.json')
        $entry = Join-Path $script:Repository 'scripts\Invoke-LabElevated.ps1'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$entry`" -Action $Action -ConfigPath `"$($c.ConfigPath)`" -ResultPath `"$resultPath`""
        $start = @{ FilePath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"; ArgumentList = $arguments; PassThru = $true; Wait = $true }
        if (-not $elevated) { $start.Verb = 'RunAs' }
        else { $start.NoNewWindow = $true }
        $process = Start-Process @start
        if (-not (Test-Path -LiteralPath $resultPath)) { throw "Elevated command exited $($process.ExitCode) without a result. See $resultPath.log" }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if (-not $result.Success) { throw "$($result.Error) Log: $($result.Log)" }
        if (-not $elevated) {
            Select-String -LiteralPath $result.Log -Pattern '^\S+\s+PASS$', '^Environment manifest:' |
                ForEach-Object { Write-Host $_.Line }
        }
        Write-Host "Lab $Action completed. Log: $($result.Log)"
        return
    }
    Import-Module Hyper-V -ErrorAction Stop
    if ((Test-Path -LiteralPath $c.Root) -and -not (Test-Path -LiteralPath (Join-Path $c.Root 'state.json'))) {
        if (@(Get-ChildItem -LiteralPath $c.Root -Force | Where-Object Name -ne '.lock').Count) {
            throw 'Lab root contains unowned files; refusing to change it.'
        }
    }
    New-Item -Path $c.Root -ItemType Directory -Force | Out-Null
    if ((Get-Item -LiteralPath $c.Root).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lab root must not be a reparse point.' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $c.Root /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to protect lab root.' }
    $lock = [IO.File]::Open((Join-Path $c.Root '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        switch ($Action) {
            New { New-LabEnvironment $c }
            Test { Test-LabEnvironment (Get-LabContext $c) }
            Stop { Stop-LabEnvironment (Get-LabContext $c) }
            Start {
                $context = Get-LabContext $c
                foreach ($machine in $c.Machines | Sort-Object { $_.Role -ne 'DC' }) {
                    $vm = Get-OwnedVM $context $machine
                    if ($vm.State -eq 'Off') { Start-VM -VM $vm | Out-Null }
                    Wait-SSH $context $machine -Domain
                }
                Test-LabEnvironment $context
            }
            Remove { Remove-LabEnvironment (Get-LabContext $c) }
            Reset {
                Remove-LabEnvironment (Get-LabContext $c)
                New-LabEnvironment $c
            }
        }
    }
    finally { $lock.Dispose() }
}

Export-ModuleMember -Function Invoke-Lab
