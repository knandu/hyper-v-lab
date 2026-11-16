# Hyper-V cluster lab

An independent personal lab by **knandu**, not an official Microsoft project.
Given a generalized Windows Server 2025 VHDX and a Windows Hyper-V host, this
repository creates an isolated AD/DNS VM and a three-node Windows Failover
Cluster. The cluster nodes are not Hyper-V hosts and have no shared storage.

## Why this exists

Many distributed-systems, clustering, control-plane, and infrastructure-management
ideas are difficult to evaluate in isolation. This repository provides a
reproducible Windows Server substrate that can be rebuilt on demand and consumed
by higher-level experiments.

The lab deliberately separates infrastructure provisioning from workload logic,
allowing architectural ideas to be evaluated without embedding environment
creation into every experiment. Related repositories build on this foundation and
focus on the systems questions they are intended to explore.

## Requirements

- Run on the target Windows Hyper-V host. Windows PowerShell 5.1, the Hyper-V
  module, and Windows OpenSSH client tools must be available.
- Administrator access through UAC; scripts request elevation automatically.
- A generalized, Generation 2-compatible Server 2025 VHDX, resealed to OOBE,
  with OpenSSH Server already installed. No guest downloads are performed.
  ISO installation and non-generalized disks are intentionally not supported.
- At least 20 GiB free host RAM for the default configuration, sufficient disk
  space for four growing differencing disks, and an unchanged base image.
- Review `config\lab.psd1` before creating the lab. Its default image path and
  SHA-256 identify the supplied local media. Supply appropriately licensed
  media; this repository does not activate or redistribute Windows.

The checked-in configuration is a concrete lab example, not a source for the
Windows image. Set `Image` and `ImageSHA256` for your own licensed, generalized
image before creating a new lab. The `wfclab.test` domain, machine/switch names,
private addresses and static MACs describe this disposable lab, not an external
organization's infrastructure.

## Topology

| Machine | Management | Cluster-private |
|---|---|---|
| Host | 192.168.241.1 | none |
| Lab-DC | 192.168.241.10 | none |
| Node-A | 192.168.241.11 | 192.168.242.11 |
| Node-B | 192.168.241.12 | 192.168.242.12 |
| Node-C | 192.168.241.13 | 192.168.242.13 |
| wfcluster | 192.168.241.20 | none |

Both networks are /24. `wfclab-management` is an **internal** switch;
`wfclab-private` is a **private** switch. Guests have no default gateway,
external-switch NIC, NAT, or dependency on corporate DNS. Host forwarding on the
lab interface is disabled. The host's existing switches, DNS configuration and
external interfaces are not changed. Private NICs do not register DNS records.
The cluster uses the management network for client access and inter-node
traffic, and the private network for inter-node traffic only.

The domain is `wfclab.test`. Each VM has two vCPUs and 4 GiB fixed RAM. VM names
are prefixed `wfclab-`; guest computer names are not.

## Lifecycle

From the repository directory:

```powershell
.\scripts\New-Lab.ps1
.\scripts\Test-Lab.ps1
.\scripts\Stop-Lab.ps1
.\scripts\Start-Lab.ps1
.\scripts\Reset-Lab.ps1
.\scripts\Remove-Lab.ps1
```

All commands accept `-ConfigPath`. Reset and removal support `-WhatIf` and ask
for confirmation; use `-Confirm:$false` in an unattended harness. Approve the
UAC prompt when starting from a non-elevated terminal. Commands are serialized
by an exclusive host-side file lock. Elevated transcripts and command results
are stored under the ignored `.lab` directory.

`New-Lab` verifies the base-image hash and rejects name/network collisions.
It creates four differencing disks without modifying the parent. It then
bootstraps SSH, creates AD/DNS, joins the nodes, installs Failover-Clustering,
runs non-storage cluster validation, creates the cluster, and checks core-group
movement between nodes. Three-node majority quorum needs no witness in this
single-host lab.

`Test-Lab` fails explicitly if guest identity, domain trust, AD DNS, SSH,
cluster membership/resources/network roles, or topology isolation is wrong.
Its successful output includes each machine plus AD/DNS, Domain, SSH, Cluster
and Isolation.

`Stop-Lab` shuts down nodes before the DC; `Start-Lab` starts the DC first.
`Reset-Lab` **destroys and reconstructs the whole environment**, including AD,
cluster identities, passwords, SSH client credentials, host keys and pins.
It does not restore potentially inconsistent domain/cluster checkpoints.
Refresh the environment manifest after every reset.

A failed creation leaves ownership state and resources for inspection. Fix the
cause, then use `Reset-Lab` to reconstruct or `Remove-Lab` to clean up. An
already-ready `New-Lab` runs health checks instead of creating duplicates.
Do not edit configuration while its lab exists: remove it with the original
configuration first. Lifecycle operations verify recorded Hyper-V resource IDs
and ownership markers before changing or deleting resources. The base image,
unrelated VMs/switches and transcripts are preserved.

## Transport and credentials

PowerShell Direct is used **only for the initial local-host bootstrap** of
networking, SSH configuration, the guest worker script, and host-key retrieval.
It does not require WinRM, guest networking, tunnels, or corporate credentials.
Host keys are obtained over that trusted VM-bus connection, not trusted from a
network scan. All subsequent guest administration uses SSH with
`StrictHostKeyChecking=yes`, a dedicated client key, and the recorded pins.
Passwords and keyboard-interactive SSH authentication are disabled.

Runtime files live in `C:\vm\labs\wfclab` by default, ACL-restricted to the
creating host user, SYSTEM and local Administrators. They include:

- `environment.json`: the consumer contract, with cluster/domain/node addresses
  and paths to the SSH key and known-hosts file; no passwords or private-key data.
- `credential.xml`: a randomly generated lab credential protected by Windows
  DPAPI for the creating host user.
- `id_ed25519` and `known_hosts`: host-local SSH credentials and trusted pins.
- `state.json`: resource ownership and provisioning state.
- `failover.json`: the successful core-group move-and-return result.

For example, consume the manifest on this host:

```powershell
$environment = Get-Content 'C:\vm\labs\wfclab\environment.json' -Raw | ConvertFrom-Json
$node = $environment.Machines | Where-Object Name -eq 'Node-A'
ssh.exe -o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes `
    -o "UserKnownHostsFile=$($environment.SSH.KnownHosts)" `
    -i $environment.SSH.PrivateKey -l $environment.SSH.User $node.Address hostname
```

Provisioning stages with credentials use protected temporary request files
staged over SCP, not long inline remote commands. Cluster creation uses a
temporary password-logon scheduled task inside the guest, so multi-node
configuration has its own lab-domain credentials rather than relying on SSH
credential delegation. Requests and the task are removed afterward. Initial
unattended-setup files are removed from the guest after bootstrap. Treat the
runtime directory and guest disks as credentials; do not publish or copy them
into the experimental repository.

The ignored `.lab` transcripts/results are also local-only: they can contain
hostnames, user identities, local paths and diagnostic details. Publish only
reviewed, sanitized evidence, not the runtime directory or raw transcripts.
Ignore rules do not sanitize Git history or files added with `git add -f`.

This is a functional control-plane lab, not a production availability design:
all machines share one physical host, storage validation is excluded, no
workload/storage fabric is provisioned, and no Internet connectivity is added.
Full cluster validation reports remain on Node-A at
`C:\Lab\ClusterValidation.htm`.

## Development

The focused tests use the host's installed Pester:

```powershell
powershell.exe -NoProfile -Command 'Invoke-Pester -Script .\tests -EnableExit'
```

Live acceptance is `New-Lab`, `Test-Lab`, stop/start, then reset and another
`Test-Lab`. All infrastructure is kept in this repository; a consumer needs
only the manifest and host-side SSH transport.

## License

[MIT](LICENSE). Copyright (c) 2026 knandu.
Windows installation media and VM images are not included; their licensing is
separate from this repository's source code and documentation.

## Primary references

- [Manage Windows Virtual Machines with PowerShell Direct](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/powershell-direct).
- [Get started with OpenSSH Server for Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse).
- [OpenSSH Server Configuration for Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration).
- [Create a failover cluster](https://learn.microsoft.com/en-us/windows-server/failover-clustering/create-failover-cluster).
- [`Test-Cluster`](https://learn.microsoft.com/en-us/powershell/module/failoverclusters/test-cluster?view=windowsserver2025-ps) and [`New-Cluster`](https://learn.microsoft.com/en-us/powershell/module/failoverclusters/new-cluster?view=windowsserver2025-ps).
