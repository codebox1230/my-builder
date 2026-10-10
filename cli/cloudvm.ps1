#!/usr/bin/env pwsh
###############################################################################
# cloudvm.ps1 — CLI for the my-builder cloud CI fleet.
#
#   Operates GitHub-hosted session VMs (Windows RDP / macOS Screen Sharing)
#   registered to a public repo, all reachable over Tailscale. No secrets in
#   this file: auth comes from `gh` (codebox1230 account) and the local
#   SSH key at ~/.ssh/cloud-builder.
#
# Commands:
#   status                        List recent runs + online tailnet session VMs
#   up --os windows|mac [--hours N]
#                                 Start a session VM (waits for tailnet join)
#   ssh [--os windows|mac] [--run ID] [-- command...]
#                                 Open interactive SSH or run a remote command
#   push <local> <remote> [--os ...]   scp a file TO the session VM
#   pull <remote> <local> [--os ...]   scp a file FROM the session VM
#   down [--os windows|mac]       Cancel in-progress session runs
#   build --repo owner/name [--branch B] [--runner R]
#                                 Headless cloud build, wait, download artifacts
#
# Env overrides: CLOUDVM_REPO (default codebox1230/my-builder),
#   CLOUDVM_KEY (default ~/.ssh/cloud-builder).
###############################################################################
# No param() block on purpose: `--flag` tokens must flow through as plain
# strings. A declared param block makes PowerShell reject unknown --flags
# before this code ever runs.
$Command = if ($args.Count -gt 0) { $args[0] } else { "help" }

$Repo = if ($env:CLOUDVM_REPO) { $env:CLOUDVM_REPO } else { "codebox1230/my-builder" }
$KeyPath = if ($env:CLOUDVM_KEY) { $env:CLOUDVM_KEY } else { "$HOME/.ssh/cloud-builder" }
$TailScale = "$env:ProgramFiles\Tailscale\tailscale.exe"
$SshExe = "C:\Windows\System32\OpenSSH\ssh.exe"
$ScpExe = "C:\Windows\System32\OpenSSH\scp.exe"
if (-not (Test-Path $SshExe)) { $SshExe = "ssh" }
if (-not (Test-Path $ScpExe)) { $ScpExe = "scp" }
$SshBase = @("-i", $KeyPath, "-o", "StrictHostKeyChecking=no",
  "-o", "UserKnownHostsFile=NUL", "-o", "BatchMode=yes",
  "-o", "ConnectTimeout=20")

function Get-Peers {
  $raw = & $TailScale status --json 2>$null | Out-String
  if (-not $raw) { return @() }
  $st = $raw | ConvertFrom-Json
  $out = @()
  foreach ($p in $st.Peer.PSObject.Properties) {
    $n = $p.Value
    if ($n.Online) {
      $out += [pscustomobject]@{ Hostname = $n.HostName; IP = $n.TailscaleIPs[0]; OS = $n.OS }
    }
  }
  return $out
}

function Find-SessionVm([string]$Os, [string]$RunId = "") {
  $prefix = if ($Os -eq "mac") { "mac-builder-" } else { "build-verify-" }
  $peers = Get-Peers | Where-Object { $_.Hostname.StartsWith($prefix) }
  if ($RunId) { $peers = $peers | Where-Object { $_.Hostname -like "*$RunId*" } }
  if (-not $peers) { return $null }
  $vm = $peers | Select-Object -First 1
  $user = if ($Os -eq "mac") { "runner" } else { "Builder" }
  return [pscustomobject]@{ Hostname = $vm.Hostname; IP = $vm.IP; User = $user; OS = $Os }
}

function Wait-ForPeer([string]$Os, [string]$RunId, [int]$TimeoutSec = 600) {
  $elapsed = 0
  while ($elapsed -lt $TimeoutSec) {
    $vm = Find-SessionVm $Os $RunId
    if ($vm) { return $vm }
    Start-Sleep -Seconds 15
    $elapsed += 15
  }
  return $null
}

function Get-Flag([string[]]$A, [string]$Name, [string]$Default = "") {
  for ($i = 0; $i -lt $A.Count; $i++) {
    if ($A[$i] -eq "--$Name" -and ($i + 1) -lt $A.Count) { return $A[$i + 1] }
    if ($A[$i] -like "--$Name=*") { return $A[$i].Substring($Name.Length + 3) }
  }
  return $Default
}

# PowerShell consumes a bare `--` itself (end-of-parameters marker), so it
# never reaches $args. Parse `--os value` / `--run value` pairs and treat
# every other token as a positional (remote command or paths).
function Split-Args([string[]]$A) {
  $os = ""; $run = ""; $pos = @()
  $i = 0
  while ($i -lt $A.Count) {
    $t = $A[$i]
    if ($t -eq "--os" -and ($i + 1) -lt $A.Count) { $os = $A[$i + 1]; $i += 2 }
    elseif ($t -eq "--run" -and ($i + 1) -lt $A.Count) { $run = $A[$i + 1]; $i += 2 }
    elseif ($t -eq "--command" -or $t -eq "-c") {
      if (($i + 1) -lt $A.Count) { $pos += $A[$i + 1] }
      $i += 2
    }
    elseif ($t -eq "--") { $i += 1 }
    else { $pos += $t; $i += 1 }
  }
  return @{ os = $os; run = $run; pos = $pos }
}

function Show-Help {
  Get-Content $PSCommandPath | Select-String "^#   " |
    ForEach-Object { $_.Line.Substring(1) }
}

# ---- argument parsing -----------------------------------------------------
# $Command is $args[0], so the real arguments start at index 1.
$rest = @()
for ($i = 1; $i -lt $args.Count; $i++) { $rest += $args[$i] }

switch ($Command) {
  "status" {
    Write-Output "== Recent runs ($Repo) =="
    gh run list --repo $Repo --limit 8
    Write-Output ""
    Write-Output "== Online session VMs (tailnet) =="
    $peers = Get-Peers | Where-Object {
      $_.Hostname.StartsWith("mac-builder-") -or $_.Hostname.StartsWith("build-verify-")
    }
    if ($peers) { $peers | Format-Table Hostname, IP, OS }
    else { Write-Output "(none)" }
  }

  "up" {
    $os = Get-Flag $rest "os" "windows"
    $hours = Get-Flag $rest "hours" "2"
    if ($os -eq "mac") {
      $url = gh workflow run mac-screen.yml --repo $Repo `
        -f private_repo="" -f session_hours=$hours -f browser_link=false
    } else {
      $url = gh workflow run rdp-cloud-vm.yml --repo $Repo `
        -f enable_rdp=true -f session_hours=$hours -f tunnel_type=tailscale
    }
    $runId = ($url | Select-String "\d+$").Matches.Value
    Write-Output "Dispatched run $runId. Waiting for tailnet join..."
    $vm = Wait-ForPeer $os $runId
    if ($vm) {
      Write-Output "VM online: $($vm.Hostname) at $($vm.IP) (user $($vm.User))"
    } else {
      Write-Output "Timed out waiting for tailnet join. Check: gh run view $runId --repo $Repo"
    }
  }

  "ssh" {
    $p = Split-Args $rest
    if (-not $p.os) {
      # auto-detect: prefer whichever session VM is online
      $vm = Find-SessionVm "windows" $p.run
      if (-not $vm) { $vm = Find-SessionVm "mac" $p.run }
      if (-not $vm) { Write-Error "No session VM online."; exit 1 }
    } else {
      $vm = Find-SessionVm $p.os $p.run
      if (-not $vm) { Write-Error "No $($p.os) session VM online."; exit 1 }
    }
    $target = "$($vm.User)@$($vm.IP)"
    if ($p.pos.Count -gt 0) {
      & $SshExe @SshBase $target ($p.pos -join " ")
    } else {
      & $SshExe @SshBase $target
    }
  }

  { $_ -in "push", "pull" } {
    $p = Split-Args $rest
    if ($p.pos.Count -lt 2) { Write-Error "Usage: cloudvm $($Command) <src> <dst> [--os ..]"; exit 1 }
    if (-not $p.os) {
      $vm = Find-SessionVm "windows" $p.run
      if (-not $vm) { $vm = Find-SessionVm "mac" $p.run }
      if (-not $vm) { Write-Error "No session VM online."; exit 1 }
    } else {
      $vm = Find-SessionVm $p.os $p.run
      if (-not $vm) { Write-Error "No $($p.os) session VM online."; exit 1 }
    }
    if ($Command -eq "push") {
      & $ScpExe @SshBase $p.pos[0] "$($vm.User)@$($vm.IP):$($p.pos[1])"
    } else {
      & $ScpExe @SshBase "$($vm.User)@$($vm.IP):$($p.pos[0])" $p.pos[1]
    }
  }

  "down" {
    $os = Get-Flag $rest "os" ""
    $runs = gh run list --repo $Repo --status in_progress --json databaseId,workflowName 2>$null | ConvertFrom-Json
    foreach ($r in $runs) {
      $isMac = $r.workflowName -like "*Mac*"
      $isWin = $r.workflowName -like "*Cloud VM*"
      $match = ($os -eq "") -or ($os -eq "mac" -and $isMac) -or ($os -eq "windows" -and $isWin)
      if (-not $match) { continue }
      Write-Output "Cancelling $($r.databaseId) ($($r.workflowName))..."
      gh run cancel $r.databaseId --repo $Repo | Out-Null
    }
    Write-Output "Done."
  }

  "build" {
    $repo = Get-Flag $rest "repo" ""
    if (-not $repo) { Write-Error "Usage: cloudvm build --repo owner/name [--branch B] [--runner R]"; exit 1 }
    $branch = Get-Flag $rest "branch" "main"
    $runner = Get-Flag $rest "runner" "ubuntu-latest"
    $bcmd = Get-Flag $rest "build-command" ""
    $apath = Get-Flag $rest "artifact-path" ""
    $url = gh workflow run build-private.yml --repo $Repo -f repo=$repo `
      -f branch=$branch -f runner=$runner -f build_command=$bcmd -f artifact_path=$apath
    $runId = ($url | Select-String "\d+$").Matches.Value
    Write-Output "Build run $runId started. Waiting..."
    gh run watch $runId --repo $Repo --exit-status 2>&1 | Select-Object -Last 3
    $dest = ".cloud-build-artifacts/$runId"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    gh run download $runId --repo $Repo --dir $dest
    Write-Output "Artifacts in $dest"
  }

  default { Show-Help }
}
