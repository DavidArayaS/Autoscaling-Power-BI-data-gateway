<#
.SYNOPSIS
  Fully automated install of .NET 4.8, Power BI Gateway, and cluster-join on a fresh VM.

.DESCRIPTION
  1) Bootstraps itself under PowerShell 7 if needed.
  2) Logs to C:\temp\gateway-install.log.
  3) Installs .NET 4.8 if absent, then reboots & resumes.
  4) Silently installs the On-Premises Data Gateway.
  5) Uses DataGateway module to authenticate via SP and join cluster.
  6) Cleans up after itself.

.NOTES
  - Hard-coded values below—update only tenant/SP/keys/IDs if they change.
  - Service Principal must be a **Gateway Admin** on ‘your cluster’.
  
   This script comes with no warranty, use at your own risk!!!
#>

#--------------------------------------
# 0) PS7 Bootstrap
#--------------------------------------
$scriptPath = $MyInvocation.MyCommand.Path
$ps7Path    = 'C:\Program Files\PowerShell\7\pwsh.exe'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Output "PowerShell 7 not found in this session. Installing PS7..."
    New-Item -ItemType Directory -Path C:\temp -Force | Out-Null

    $msi = 'C:\temp\PowerShell7.msi'
    Invoke-WebRequest -UseBasicParsing `
      -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.5.2/PowerShell-7.5.2-win-x64.msi' `
      -OutFile $msi

    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait

    Write-Output "Relaunching script under PowerShell 7..."
    if (-not (Test-Path $ps7Path)) {
        Write-Error "Unable to locate pwsh.exe at $ps7Path"
        exit 1
    }
    & $ps7Path -NoProfile -ExecutionPolicy Bypass -File $scriptPath
    exit
}

#--------------------------------------
# Now running under PowerShell 7
#--------------------------------------
Start-Transcript -Path 'C:\temp\gateway-install.log' -Append
New-Item -ItemType Directory -Path 'C:\temp' -Force | Out-Null

#--------------------------------------
# 1) Install .NET 4.8 if needed
#--------------------------------------
$dotnetKey      = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
$dotnetVersion  = (Get-ItemProperty -Path $dotnetKey -ErrorAction SilentlyContinue).Release
$dotnetRequired = 528040

if (-not $dotnetVersion -or $dotnetVersion -lt $dotnetRequired) {
    Write-Output "Installing .NET Framework 4.8..."
    Invoke-WebRequest -UseBasicParsing `
      -Uri 'https://go.microsoft.com/fwlink/?linkid=2088631' `
      -OutFile 'C:\temp\ndp48.exe'
    Start-Process -FilePath 'C:\temp\ndp48.exe' -ArgumentList '/quiet','/norestart' -Wait

    Write-Output "Scheduling script to resume after reboot..."
    $action  = New-ScheduledTaskAction -Execute $ps7Path `
               -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:00:30
    Register-ScheduledTask -TaskName 'ReRunGatewayInstall' `
                           -Action $action `
                           -Trigger $trigger `
                           -RunLevel Highest `
                           -User 'SYSTEM'

    Write-Output "Rebooting now..."
    Restart-Computer -Force
    Stop-Transcript
    exit
}
Write-Output ".NET Framework 4.8 present."

#--------------------------------------
# 2) Install Power BI On-Premises Data Gateway
#--------------------------------------
$installerUrl  = 'https://go.microsoft.com/fwlink/?LinkId=2116849&clcid=0x409'
$installerPath = 'C:\temp\PBIDGatewayInstaller.exe'

Write-Output "Downloading Data Gateway..."
Invoke-WebRequest -UseBasicParsing -Uri $installerUrl -OutFile $installerPath

Write-Output "Installing Data Gateway..."
Start-Process -FilePath $installerPath -ArgumentList '/quiet','/norestart' -Wait

#--------------------------------------
# 3) Headless Cluster Join via DataGateway module
#--------------------------------------
Write-Output "Installing DataGateway PowerShell module..."
Install-Module DataGateway -Scope AllUsers -Force -ErrorAction SilentlyContinue
Import-Module DataGateway
Import-Module DataGateway.Profile

Write-Output "Authenticating Service Principal..."
$tenantId      = 'your azure tenant id'
$applicationId = 'your SP App ID'
$plainSecret   = 'your SP Secret'
$spSecret      = ConvertTo-SecureString $plainSecret -AsPlainText -Force

Connect-DataGatewayServiceAccount `
  -ApplicationId $applicationId `
  -ClientSecret  $spSecret `
  -Tenant        $tenantId

Write-Output "Joining node to gateway cluster..."
$clusterId   = 'your PBI cluster ID'
$recoveryKey = 'recovery ID used to create the gateway'
$secureKey   = ConvertTo-SecureString $recoveryKey -AsPlainText -Force
$gatewayName = "$($env:COMPUTERNAME)-node"

Add-DataGatewayClusterMember `
  -RecoveryKey      $secureKey `
  -GatewayName      $gatewayName `
  -GatewayClusterId $clusterId

if ($?) {
    Write-Host "Successfully joined '$gatewayName' to the cluster."
} else {
    Write-Error "Cluster join failed. Check logs under SYSTEM profile AppData."
    exit 1
}

#--------------------------------------
# 4) Cleanup
#--------------------------------------
Unregister-ScheduledTask -TaskName 'ReRunGatewayInstall' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item 'C:\temp\ndp48.exe','C:\temp\PBIDGatewayInstaller.exe','C:\temp\PowerShell7.msi' -Force -ErrorAction SilentlyContinue

Stop-Transcript