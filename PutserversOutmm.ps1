asnp citrix*
# Archivo con la lista de servidores (uno por línea)

$machineNames = Get-Content -Path "$($PsScriptRoot)\serverlist.txt"

# Lista de AdminAddress (DDC servers)
$adminAddresses = Get-Content -Path "$($PsScriptRoot)\DDCList.txt"

Write-Host "Servers to take out of mm:"
$machineNames
$input = Read-Host "Are you sure you want to take above server out of mm ?   to continue enter 'y' or anything to abort"

if ($input -eq "y") {
    Write-Host "Working on it..."
} else {
    Write-Host "Canceled."
    exit
}

# To store results
$results = @()

foreach ($machineName in $machineNames) {
    Write-Host "Working on server: $machineName"
    $found = $false
    foreach ($adminAddress in $adminAddresses) {
        # Intentar buscar la máquina en el DDC
        $format = "ASTRAZENECA\$machineName"
        #Write-Host "searching  on: $adminAddress"
        try{
            $machine = Get-BrokerMachine -MachineName $format -AdminAddress $adminAddress -ErrorAction SilentlyContinue 
        } catch {
            Write-Host "ddc error on: $adminAddress"
            Write-Host "Error Message: $($_.Exception.Message)" -ForegroundColor Red
            $machine =$null
        }
        if ($null -ne $machine) {
            $name = $machine.DNSName
            if($machine.RegistrationState -eq 'Registered'){
                try{
                    Set-BrokerMachineMaintenanceMode  -InputObject $machine $false
                    $machine = Get-BrokerMachine -MachineName $format -AdminAddress $adminAddress -ErrorAction SilentlyContinue 
                } catch {
                    Write-Host "Error while putting server in maintenence mode"
                    Write-Host "Error Message: $($_.Exception.Message)" -ForegroundColor Red
                    $machine =$null
                }
                $results += [PSCustomObject]@{
                    MachineName     = $machine.DNSName
                    SessionCount    = $machine.SessionCount
                    InMaintenanceMode    = $machine.InMaintenanceMode
                    RegistrationState    = $machine.RegistrationState
                    FoundOnDDC      = $adminAddress
                }
                $found = $true
                break  # Ya encontrada, no buscar en otros DDC
            }else{
                #The machine is not registered hence infromation is not acurate
                Write-Host "$name found on: $adminAddress  but server is unregistered (information is not acurate)"
                continue
            }
            
        }
    }
    if (-not $found) {
        $results += [PSCustomObject]@{
            MachineName     = $machineName
            SessionCount    = "Not found"
            InMaintenanceMode      = "Not found"
            RegistrationState      = "Not found"
            FoundOnDDC      = "Not found"
        }
    }
}
$results
# Exportar a CSV
$results | Export-Csv -Path "Results.csv" -NoTypeInformation -Encoding UTF8