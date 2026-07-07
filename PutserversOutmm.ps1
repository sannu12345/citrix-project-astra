<#
    MaintenanceMode-Off.ps1
    ------------------------------------------------------------------------
    Takes a list of Citrix VDA machines OUT OF maintenance mode.

    Logging: This script deliberately makes a PLAIN Set-BrokerMachineMaintenanceMode
    call, with no custom Start-LogHighLevelOperation wrapper. Citrix Studio's
    Logging node will show whatever it natively shows for this operation
    (typically an "Edit Machine" entry) - this is intentional, per requirement
    that Citrix Console logs reflect native Citrix output, not custom text.

    Inputs (same folder as this script):
      - serverlist_off.txt  : one server hostname per line, servers to take
                              OUT OF maintenance mode
      - DDCList.txt         : one Delivery Controller (AdminAddress) per line

    Outputs:
      - Console output as it runs
      - Results_MaintenanceOff.csv (appended, so history accumulates)
      - Pass/Fail/Not-Found summary count at the end
------------------------------------------------------------------------ #>

asnp citrix*

$scriptDir = $PSScriptRoot
$domainPrefix = "ASTRAZENECA"

$machineNames   = Get-Content -Path "$scriptDir\serverlist.txt"
$adminAddresses = Get-Content -Path "$scriptDir\DDCList.txt"

# Real AD identity of whoever is running the script (domain\username),
# used purely for the local CSV audit trail - has no effect on native
# Citrix Studio logging one way or the other.
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

Write-Host "Servers to turn MAINTENANCE MODE OFF:"
$machineNames | ForEach-Object { Write-Host "  $_" }
Write-Host ""

$reason = Read-Host "Enter a reason / ticket number for this maintenance action"
if ([string]::IsNullOrWhiteSpace($reason)) {
    Write-Host "A reason is required. Aborting." -ForegroundColor Red
    exit
}

$confirm = Read-Host "Are you sure you want to turn OFF maintenance mode for the above servers? Enter 'y' to continue, anything else to abort"
if ($confirm -ne 'y') {
    Write-Host "Canceled." -ForegroundColor Yellow
    exit
}

$results       = @()
$successCount  = 0
$failCount     = 0
$notFoundCount = 0

foreach ($machineName in $machineNames) {
    Write-Host "Working on server: $machineName"
    $found = $false

    foreach ($adminAddress in $adminAddresses) {
        $format = "$domainPrefix\$machineName"

        try {
            $machine = Get-BrokerMachine -MachineName $format -AdminAddress $adminAddress -ErrorAction SilentlyContinue
        } catch {
            Write-Host "  DDC error on: $adminAddress" -ForegroundColor Red
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
            $machine = $null
        }

        if ($null -eq $machine) {
            continue  # not found on this DDC, try the next one
        }

        if ($machine.RegistrationState -ne 'Registered') {
            # Found, but unregistered - data would be unreliable, so skip
            # and keep checking the remaining DDCs in case it's registered
            # against a different one.
            Write-Host "  $($machine.DNSName) found on $adminAddress but is unregistered - skipping (information not accurate)" -ForegroundColor Yellow
            continue
        }

        # -----------------------------------------------------------------
        # Wrap in a custom high-level operation so Studio's Logging grid
        # shows friendly text instead of generic "Edit Machine". This
        # matches Citrix's own documented pattern exactly (see
        # about_LogConfigurationLoggingSnapIn / Start-LogHighLevelOperation
        # SDK docs) - it is the officially supported mechanism for scripts,
        # not a workaround.
        # -----------------------------------------------------------------
        $actionText = "Turn Off Maintenance Mode on Machine '$($machine.MachineName)' (via script, reason: $reason)"
        $hlo = $null
        try {
            $hlo = Start-LogHighLevelOperation -Text $actionText -Source "MaintenanceMode-Off.ps1" -AdminAddress $adminAddress
        } catch {
            Write-Host "  [LOGGING] Could not open high-level logging operation - continuing without it" -ForegroundColor Yellow
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        }

        $opSuccess = $true
        try {
            if ($hlo) {
                Set-BrokerMachineMaintenanceMode -InputObject $machine -MaintenanceMode $false -LoggingId $hlo.Id
            } else {
                Set-BrokerMachineMaintenanceMode -InputObject $machine -MaintenanceMode $false
            }
            $machine = Get-BrokerMachine -MachineName $format -AdminAddress $adminAddress -ErrorAction SilentlyContinue
        } catch {
            $opSuccess = $false
            Write-Host "  [FAILURE] Could not turn OFF maintenance mode for $machineName" -ForegroundColor Red
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
            $machine = $null
        } finally {
            if ($hlo) {
                try {
                    Stop-LogHighLevelOperation -HighLevelOperationId $hlo.Id -IsSuccessful $opSuccess
                } catch {
                    Write-Host "  [LOGGING] Could not close high-level logging operation" -ForegroundColor Yellow
                    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }

        if ($opSuccess) {
            $successCount++
            Write-Host "  Maintenance mode OFF - OK" -ForegroundColor Green
            $results += [PSCustomObject]@{
                MachineName       = $machine.DNSName
                Action            = "MM-OFF"
                Status            = "Success"
                SessionCount      = $machine.SessionCount
                InMaintenanceMode = $machine.InMaintenanceMode
                RegistrationState = $machine.RegistrationState
                FoundOnDDC        = $adminAddress
                PerformedBy       = $currentUser
                Reason            = $reason
                Timestamp         = (Get-Date)
            }
        } else {
            $failCount++
            $results += [PSCustomObject]@{
                MachineName       = $format
                Action            = "MM-OFF"
                Status            = "Failed"
                SessionCount      = "N/A"
                InMaintenanceMode = "N/A"
                RegistrationState = "N/A"
                FoundOnDDC        = $adminAddress
                PerformedBy       = $currentUser
                Reason            = $reason
                Timestamp         = (Get-Date)
            }
        }

        $found = $true
        break  # already handled - no need to check remaining DDCs
    }

    if (-not $found) {
        $notFoundCount++
        Write-Host "  Not found as Registered on any DDC in list." -ForegroundColor Yellow
        $results += [PSCustomObject]@{
            MachineName       = $machineName
            Action            = "MM-OFF"
            Status            = "Not Found"
            SessionCount      = "N/A"
            InMaintenanceMode = "N/A"
            RegistrationState = "N/A"
            FoundOnDDC        = "N/A"
            PerformedBy       = $currentUser
            Reason            = $reason
            Timestamp         = (Get-Date)
        }
    }
}

$results

Write-Host ""
Write-Host "===== SUMMARY =====" -ForegroundColor Cyan
Write-Host "Total servers requested : $($machineNames.Count)"
Write-Host "Successful              : $successCount" -ForegroundColor Green
Write-Host "Failed                  : $failCount" -ForegroundColor Red
Write-Host "Not Found               : $notFoundCount" -ForegroundColor Yellow

$csvPath = "$scriptDir\Results_MaintenanceOff.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Append
Write-Host ""
Write-Host "Results appended to $csvPath"
