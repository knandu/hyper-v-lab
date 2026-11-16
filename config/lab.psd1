@{
    Name = 'wfclab'
    Root = 'C:\vm\labs\wfclab'
    Image = 'C:\vm\images\ws2025\26100.1.amd64fre.ge_release.240331-1435_server_serverdatacenter_en-us_vl.vhdx'
    ImageSHA256 = 'BE7E0D9F272040E802774785F771EFCB8B08DB7F946991034693D85630834C36'
    Domain = 'wfclab.test'
    NetBIOS = 'WFLAB'
    Administrator = 'labadmin'
    ManagementSwitch = 'wfclab-management'
    PrivateSwitch = 'wfclab-private'
    HostAddress = '192.168.241.1'
    PrefixLength = 24
    ClusterName = 'wfcluster'
    ClusterAddress = '192.168.241.20'
    ProcessorCount = 2
    MemoryBytes = 4GB
    TimeoutSeconds = 900
    Machines = @(
        @{ Name = 'Lab-DC'; Role = 'DC'; Address = '192.168.241.10'; PrivateAddress = ''; ManagementMAC = '00155D71F110'; PrivateMAC = '' }
        @{ Name = 'Node-A'; Role = 'Node'; Address = '192.168.241.11'; PrivateAddress = '192.168.242.11'; ManagementMAC = '00155D71F111'; PrivateMAC = '00155D71F211' }
        @{ Name = 'Node-B'; Role = 'Node'; Address = '192.168.241.12'; PrivateAddress = '192.168.242.12'; ManagementMAC = '00155D71F112'; PrivateMAC = '00155D71F212' }
        @{ Name = 'Node-C'; Role = 'Node'; Address = '192.168.241.13'; PrivateAddress = '192.168.242.13'; ManagementMAC = '00155D71F113'; PrivateMAC = '00155D71F213' }
    )
}
