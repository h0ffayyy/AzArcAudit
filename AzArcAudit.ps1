<#
    .SYNOPSIS
    This script audits Azure Arc machines and creates a report with recommendations.

    .DESCRIPTION
    This script checks the status of Azure Arc machines, their agent versions, and their extension versions.
    It then creates a report with recommendations for each machine.

    .PARAMETER None

    .OUTPUTS
    A CSV file with the report data.

    .EXAMPLE
    .\ArcAudit.ps1

    .EXAMPLE
    .\ArcAudit.ps1 -Verbose

    .LINK
    https://github.com/h0ffayyy/AzArcAudit

    .NOTES
    Author:     Aaron Hoffmann
    Date:       2025-02-24
    Version:    1.0
#>

[CmdletBinding()]
param()

function Invoke-CreateReport {
    param (
        [Parameter(Mandatory = $true)]
        [array]$reportData
    )
    
    Write-Host "[+] Creating report..."

    # Filter out any null entries before processing
    $validReportData = $reportData | Where-Object { $_ -ne $null }

    foreach ($machine in $validReportData) {
        $reportEntry = [PSCustomObject]@{
            MachineName             = $machine.Name
            MachineFqdn             = $machine.DnsFqdn
            OSType                  = $machine.OSType
            Status                  = $machine.Status
            AgentConfigurationMode  = $machine.AgentConfigurationConfigMode
            AgentAutomaticUpgrades  = $machine.AgentUpgradeEnableAutomaticUpgrade
            AgentVersion            = $machine.AgentVersion
            UpdateAvailable         = ($machine.AgentVersion -lt $machine.LatestAgentVersion)
            InstalledExtensions     = $machine.InstalledExtensions
            Recommendations         = ($machine.Recommendations -join "`n`n")
        }

        $date = Get-Date -Format "yyyy-MM-dd"
        $reportEntry | Export-Csv -Path "ArcAudit_Report_$date.csv" -Append -NoTypeInformation
    }
}

function Get-ArcMachines {
    $arcMachines = Get-AzConnectedMachine
    return $arcMachines
}

function Connect-Azure {
    try {
        $context = Get-AzContext
        if (!$context) {
            Connect-AzAccount
            Write-Host "[" -NoNewline
            Write-Host "✓" -ForegroundColor Green -NoNewline
            Write-Host "] Signed in to Azure"
        } else {
            Write-Host "[" -NoNewline
            Write-Host "✓" -ForegroundColor Green -NoNewline
            Write-Host "] Already signed in as $($context.Account)"
        }
    } catch {
        Write-Host "[!] Failed to sign in to Azure" -ForegroundColor Red
        exit
    }
}

function Initialize-AzurePowershell {
    $azModule = Get-InstalledModule -Name Az
    if ($azModule) {
        Write-Host "[" -NoNewline
        Write-Host "✓" -ForegroundColor Green -NoNewline
        Write-Host "] Az module is installed"
    } else {
        Write-Host "[!] Az module is not installed" -ForegroundColor Red
        $installPrompt = Read-Host "[+] Would you like to install the Az module? (Y/N)"
        if ($installPrompt -eq 'Y' -or $installPrompt -eq 'y') {
            Write-Host "[+] Installing Az module..."
            Install-Module -Name Az -Force
            Write-Host "[✓] Az module installed successfully" -ForegroundColor Green
        } else {
            Write-Host "[!] Az module is required. Exiting..." -ForegroundColor Red
            exit
        }
    }
}

function Invoke-CheckWindowsAgentVersion {
    $MSUpdateCatalogUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=AzureConnectedMachineAgent"
    
    try {
        $MSUpdateCatalogResponse = Invoke-WebRequest -Uri $MSUpdateCatalogUrl -Method Get
    } catch {
        Write-Warning "[!] Could not connect to the Microsoft Update Catalog"
        return $null
    }
    
    # Parse the HTML content to find the latest available version
    if ($MSUpdateCatalogResponse -match 'AzureConnectedMachineAgent Version (\d+\.\d+)') {
        return $matches[1]
    } else {
        Write-Warning "[!] Could not find Azure Connected Machine Agent version"
        return $null
    }
}

$processedMachines = [System.Collections.ArrayList]::new()

$machineProcessingBlock = {
    param(
        $machine, 
        $latestAgentVersionWindows, 
        $latestExtensionVersion
    )
    
    function Get-LatestExtensionVersion {
        param (
            [Parameter(Mandatory = $true)]
            [string]$extensionType,
            [Parameter(Mandatory = $true)]
            [string]$extensionPublisher,
            [Parameter(Mandatory = $true)]
            [string]$extensionLocation
        )
    
        $latestExtensionVersion = $(Get-AzConnectedExtensionMetadata -ExtensionType $extensionType `
            -Location $extensionLocation `
            -Publisher $extensionPublisher)[0].version
    
        return $latestExtensionVersion
    }

    function Invoke-CheckLinuxAgentVersion {
        param (
            [Parameter(Mandatory = $true)]
            [string]$osSku
        )

        # Extract distribution and version from OSSku
        # this section probably needs some more work
        if ($osSku -match '^([a-zA-Z]+(?:\s+Linux(?:\s+Server)?)?)\s*(\d+(?:\.\d+)*(?:\s*LTS)?)\s*(?:\([^)]+\))?') {
            $distro = $matches[1].ToLower()
            if ($distro -eq 'oracle linux server') {
                $distro = 'rhel'
            }
            $version = if ($distro -eq 'ubuntu') {
                if ($matches[2] -match '(\d+\.\d+)') {
                    $matches[1]
                } else {
                    $matches[2]
                }
            } elseif ($distro -eq 'rhel') {
                if ($matches[2] -match '(\d+)') {
                    $matches[1]
                } else {
                    ($matches[2] -split '\.')[0]
                }
            } else {
                ($matches[2] -split '\s+')[0]
            }

            $repoUrl = switch ($distro) {
                'ubuntu' { "https://packages.microsoft.com/ubuntu/$version/prod/pool/main/a/azcmagent/" }
                'debian' { "https://packages.microsoft.com/debian/$version/prod/pool/main/a/azcmagent/" }
                'rhel'   { "https://packages.microsoft.com/rhel/$version/prod/Packages/a/" }
                'centos' { "https://packages.microsoft.com/centos/$version/prod/Packages/a/" }
                'sles'   { "https://packages.microsoft.com/sles/$version/prod/Packages/a/" }
                'amazonlinux' { "https://packages.microsoft.com/amazonlinux/$version/prod/Packages/a/" }
                default  { $null }
            }

            if ($repoUrl) {
                try {
                    Write-Verbose "[+]Checking Linux agent version at: $repoUrl"
                    $response = Invoke-WebRequest -Uri $repoUrl -Method Get

                    $versionPattern = 'azcmagent_(\d+\.\d+\.\d+\.\d+)_amd64\.(deb|rpm)'
                    $versions = [regex]::Matches($response.Content, $versionPattern) |
                        ForEach-Object { $_.Groups[1].Value } |
                        ForEach-Object {
                            $parts = $_ -split '\.'
                            [PSCustomObject]@{
                                VersionString = $_
                                SortableVersion = [PSCustomObject]@{
                                    Major       = [int]$parts[0]
                                    Minor       = [int]$parts[1]
                                    Build       = [int]$parts[2]
                                    Revision    = [int]$parts[3]
                                }
                            }
                        } |
                        Sort-Object -Property { $_.SortableVersion.Major },
                                            { $_.SortableVersion.Minor },
                                            { $_.SortableVersion.Build },
                                            { $_.SortableVersion.Revision } -Descending |
                        Select-Object -ExpandProperty VersionString -First 1

                    if ($versions.Count -gt 0) {
                        return $versions
                    }
                } catch {
                    Write-Warning "[!] Could not connect to the Linux package repository for $distro $version"
                    Write-Verbose -Message "Error: $_"
                    return $null
                }
            } else {
                Write-Warning "[!] Machine $($machine.Name) has an unsupported Linux distribution: $distro"
                return $null
            }
        } else {
            Write-Warning "[!] Could not parse OS SKU format: $osSku"
            return $null
        }
    }
    
    $recommendations = @()

    # Check if the agent is configured to run in full mode
    if ($machine.AgentConfigurationConfigMode -eq "full") {
        $recommendations += "Arc Agent is configured to run in the default full mode. Consider setting the agent to run in monitor mode if remote management is not required. (Ref: https://learn.microsoft.com/azure/azure-arc/servers/security-extensions#agent-modes)"
    }
    Write-Verbose -Message " ↳ Arc Agent Configuration Mode: $($machine.AgentConfigurationConfigMode)"

    # Get latest agent version based on OS type
    $latestAgentVersion = if ($machine.OSType -eq "linux") {
        Invoke-CheckLinuxAgentVersion -osSku $machine.OSSku
    } else {
        $latestAgentVersionWindows
    }

    Write-Verbose -Message " ↳ OS Type: $($machine.OSType)"
    Write-Verbose -Message " ↳ Latest Arc Agent Version: $($latestAgentVersion)"

    # Check if the agent is out of date
    if ($machine.AgentVersion -lt $latestAgentVersion) {
        Write-Verbose -Message " ↳ Arc Agent is out of date (Current: $($machine.AgentVersion), Latest: $latestAgentVersion). Consider updating to the latest version."
        $recommendations += "Arc Agent is out of date. Consider updating to the latest version (Ref: https://learn.microsoft.com/azure/azure-arc/servers/agent-release-notes)."
    }

    # Check if any extensions are out of date
    $installedExtensions = New-Object System.Collections.Generic.List[System.Object]
    
    # Get extensions for this machine using Get-AzConnectedMachineExtension
    $extensions = Get-AzConnectedMachineExtension -MachineName $machine.Name -ResourceGroupName $machine.ResourceGroupName
    
    foreach ($extension in $extensions) {
        $extensionType = $extension.InstanceViewType
        $extensionPublisher = $extension.Publisher
        $extensionLocation = $extension.Location
        $currentExtensionVersion = $extension.TypeHandlerVersion

        Write-Verbose -Message " ↳ Found Extension: $($extension.InstanceViewType) v$($extension.TypeHandlerVersion)"

        $installedExtensions.Add("$extensionType v$currentExtensionVersion")
        $latestExtensionVersion = Get-LatestExtensionVersion -extensionType $extensionType -extensionPublisher $extensionPublisher -extensionLocation $extensionLocation

        if ($currentExtensionVersion -eq $null) {
            Write-Warning "Unable to find installed version for extension $($extensionType)"
            $recommendations += "Unable to find installed version for extension $($extensionType). Please check manually."
        } elseif ($latestExtensionVersion -eq $null) {
            Write-Warning "Unable to find latest version for extension $($extensionType)"
            $recommendations += "Unable to find latest version for extension $($extensionType). Please check manually."
        } else {
            try {
                $current = [System.Version]::new($currentExtensionVersion)
                $latest = [System.Version]::new($latestExtensionVersion)
                
                if ($current -lt $latest) {
                    Write-Verbose -Message " ↳ Extension $($extensionType) is out of date (Current: $current, Latest: $latest). Consider updating to the latest version."
                    $recommendations += "Extension $($extensionType) is out of date (Current: $current, Latest: $latest). Consider updating to the latest version."
                }
            }
            catch {
                Write-Warning "Unable to compare versions for extension $($extensionType): Current=$currentExtensionVersion, Latest=$latestExtensionVersion"
                $recommendations += "Unable to verify version for extension $($extensionType). Please check manually."
            }
        }
    }

    # check if machine status is expired
    if ($machine.Status -eq "Expired") {
        $recommendations += "Machine is expired. Consider renewing the machine (Ref: https://learn.microsoft.com/azure/azure-arc/servers/overview#agent-status)."
    }

    # Return processed machine with recommendations
    $machineInfo = $machine | Select-Object *
    $machineInfo | Add-Member -NotePropertyName 'Recommendations' -NotePropertyValue $recommendations -Force
    $machineInfo | Add-Member -NotePropertyName 'LatestAgentVersion' -NotePropertyValue $latestAgentVersion -Force
    $machineInfo | Add-Member -NotePropertyName 'InstalledExtensions' -NotePropertyValue $installedExtensions.ToArray() -Force
    return $machineInfo
}

######################
# MAIN
######################


Initialize-AzurePowershell
Write-Host "[" -NoNewline
Write-Host "✓" -ForegroundColor Green -NoNewline
Write-Host "] Environment checked successfully"

Connect-Azure
Write-Host "[" -NoNewline
Write-Host "✓" -ForegroundColor Green -NoNewline
Write-Host "] Azure connected successfully"

Write-Host "[+] Getting Arc Machines..."
$arcMachines = Get-ArcMachines
Write-Host "[" -NoNewline
Write-Host "✓" -ForegroundColor Green -NoNewline
Write-Host "] Found $($arcMachines.Count) Arc Machines in this subscription"

$latestAgentVersionWindows = Invoke-CheckWindowsAgentVersion
$latestExtensionVersion = $null

$jobs = @()
$maxConcurrentJobs = 10

$totalMachines = $arcMachines.Count
for ($i = 0; $i -lt $arcMachines.Count; $i++) {
    $machine = $arcMachines[$i]
    
    $progressParams = @{
        Activity = "Setting up parallel processing jobs"
        Status = "Creating job for machine: $($machine.Name)"
        PercentComplete = ($i + 1) / $totalMachines * 100
        CurrentOperation = "Job $($i + 1) of $totalMachines"
    }
    Write-Progress @progressParams

    # Wait if we've hit the maximum number of concurrent jobs
    while ((Get-Job -State Running).Count -ge $maxConcurrentJobs) {
        Start-Sleep -Seconds 1
        $completed = Get-Job -State Completed
        if ($completed) {
            foreach ($completedJob in $completed) {
                $results = Receive-Job -Job $completedJob -Wait -WriteEvents -Verbose:$VerbosePreference
                foreach ($result in $results) {
                    if ($result) {
                        [void]$processedMachines.Add($result)
                    }
                }
                Remove-Job -Job $completedJob
            }
        }
    }

    $jobs += Start-Job -ScriptBlock $machineProcessingBlock -ArgumentList @(
        $machine,
        $latestAgentVersionWindows,
        $latestExtensionVersion
    )
}

Write-Progress -Activity "[+] Setting up parallel processing jobs" -Completed

Write-Host "[" -NoNewline
Write-Host "+" -ForegroundColor Yellow -NoNewline
Write-Host "] Waiting for remaining jobs to complete..."
Wait-Job -Job $jobs | Out-Null

# Process any remaining jobs
foreach ($job in $jobs) {
    if (Get-Job -Id $job.Id -ErrorAction SilentlyContinue) {
        $result = Receive-Job -Job $job -Wait -WriteEvents -Verbose:$VerbosePreference
        if ($result) {
            [void]$processedMachines.Add($result)
        } else {
            Write-Warning "No results received from job for machine"
            Write-Verbose -Message "Error: $($job.Exception.Message)"
        }
        Remove-Job -Job $job -ErrorAction SilentlyContinue
    }
}

Invoke-CreateReport -reportData $processedMachines
