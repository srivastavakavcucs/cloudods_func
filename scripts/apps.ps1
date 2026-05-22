<#
.SYNOPSIS
    Manage the local Azure Function and Azurite application services.

.DESCRIPTION
    Wraps commands to manage the Azurite storage emulator and Azure Functions host for local development.

    Application services:
      azurite          Azure Storage emulator -- http://127.0.0.1:10000-10002 (default, configurable)
      functions        Azure Functions host   -- http://localhost:7071/api/logging (default, configurable)

.PARAMETER Command
    Application commands:
      start-app    Stop any running app services, configure the environment,
                   then start Azurite and the Azure Functions host in separate windows.
      stop-app     Stop Azurite and the Azure Functions host.
      start-azurite    Start only the Azurite storage emulator (foreground).
      start-functions  Start only the Azure Functions host (foreground).
      test-endpoint    Send a GET request to the function's HTTP endpoint.

.PARAMETER Environment
    Environment to configure when using start-app: local | azure. Default: local.

.PARAMETER Developer
    Applies a predefined port bundle for the named developer. Overrides all individual port parameters.
      A   Functions=7071, Blob=10000, Queue=10001, Table=10002
      B   Functions=7072, Blob=10010, Queue=10011, Table=10012

.PARAMETER FunctionsPort
    Port for the Azure Functions host. Default: 7071.
    Ignored when -Developer is specified.

.PARAMETER AzuriteBlobPort
    Port for the Azurite Blob service. Default: 10000.
    Ignored when -Developer is specified.

.PARAMETER AzuriteQueuePort
    Port for the Azurite Queue service. Default: 10001.
    Ignored when -Developer is specified.

.PARAMETER AzuriteTablePort
    Port for the Azurite Table service. Default: 10002.
    Ignored when -Developer is specified.

.EXAMPLE
    .\run.ps1 apps start-app -Developer A
    .\run.ps1 apps start-app -Developer B
    .\run.ps1 apps start-app -Developer B -Environment azure
    .\run.ps1 apps stop-app
    .\run.ps1 apps test-endpoint -Developer A
    .\run.ps1 apps test-endpoint -Developer B
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet("help", "start-app", "stop-app", "start-azurite", "start-functions", "test-endpoint")]
    [string]$Command,

    [ValidateSet("local", "azure")]
    [string]$Environment = "local",

    [ValidateSet("A", "B")]
    [string]$Developer = "",

    [int]$FunctionsPort = 7071,
    [int]$AzuriteBlobPort = 10000,
    [int]$AzuriteQueuePort = 10001,
    [int]$AzuriteTablePort = 10002
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot

$portCommands = @("start-app", "stop-app", "start-azurite", "test-endpoint")
if ($Developer -eq "" -and $Command -in $portCommands) {
    do {
        $Developer = Read-Host "Developer (A or B)"
    } while ($Developer -notin @("A", "B"))
}

if ($Developer -eq "A") {
    $FunctionsPort    = 7071
    $AzuriteBlobPort  = 10000
    $AzuriteQueuePort = 10001
    $AzuriteTablePort = 10002
}
elseif ($Developer -eq "B") {
    $FunctionsPort    = 7072
    $AzuriteBlobPort  = 10010
    $AzuriteQueuePort = 10011
    $AzuriteTablePort = 10012
}

$EnvFile     = Join-Path $projectRoot ".env"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    Write-Host "`n" + ("=" * 80) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
}

function Show-Help {
    Write-Host @"
================================================================================
     ODS Azure Function and Azurite Manager
================================================================================

USAGE:
    .\run.ps1 apps <command> [options]

APPLICATION COMMANDS:
    start-app        Configure ports, start Azurite and Azure Functions host
    stop-app         Stop Azurite and the Azure Functions host
    start-azurite    Start only the Azurite storage emulator (foreground)
    start-functions  Start only the Azure Functions host (foreground)
    test-endpoint    Send a GET request to the function HTTP endpoint

OPTIONS:
    -Developer <A|B>     Select port bundle for Developer A or B (prompts if omitted
                         on commands that need it)
    -Environment <env>   Settings environment for start-app: local | azure
                         Default: local
    -FunctionsPort <n>   Override Functions port (ignored when -Developer is set)
    -AzuriteBlobPort <n> Override Azurite Blob port (ignored when -Developer is set)
    -AzuriteQueuePort <n>Override Azurite Queue port (ignored when -Developer is set)
    -AzuriteTablePort <n>Override Azurite Table port (ignored when -Developer is set)

PORT BUNDLES:
    Developer A   Functions=7071  Blob=10000  Queue=10001  Table=10002
    Developer B   Functions=7072  Blob=10010  Queue=10011  Table=10012

EXAMPLES:
    .\run.ps1 apps help
    .\run.ps1 apps start-app -Developer A
    .\run.ps1 apps start-app -Developer B -Environment azure
    .\run.ps1 apps test-endpoint -Developer B
    .\run.ps1 apps stop-app
"@
}

# ---------------------------------------------------------------------------
# Application service helpers
# ---------------------------------------------------------------------------

function Read-EnvFile {
    param([string]$Path)
    $values = @{}
    if (Test-Path $Path) {
        foreach ($line in Get-Content $Path) {
            $line = $line.Trim()
            if ($line -and -not $line.StartsWith('#')) {
                $key, $val = $line -split '=', 2
                $values[$key.Trim()] = $val.Trim()
            }
        }
    }
    return $values
}

function Get-PidOnPort {
    param([int]$Port)
    $match = netstat -ano 2>$null | Select-String ":$Port\s+" | Select-String "LISTENING" | Select-Object -First 1
    if ($match) {
        $parts = ($match -split '\s+') | Where-Object { $_ }
        return [int]$parts[-1]
    }
    return $null
}

function Stop-AppServices {
    Write-Section "Stopping Application Services (Developer $Developer)"

    # --- Azure Functions host: find by its listening port ---
    $funcPid = Get-PidOnPort $FunctionsPort
    if ($funcPid) {
        # Walk up the process tree before killing the child — func may sit behind cmd.exe (func.cmd)
        # so the wrapper powershell may not be the direct parent
        $funcWrapperPid = $null
        $searchPid = $funcPid
        for ($i = 0; $i -lt 3; $i++) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$searchPid" -ErrorAction SilentlyContinue
            if (-not $proc) { break }
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction SilentlyContinue
            if ($parent -and $parent.Name -eq 'powershell.exe' -and $parent.CommandLine -like '*func host start*') {
                $funcWrapperPid = $proc.ParentProcessId
                break
            }
            $searchPid = $proc.ParentProcessId
        }

        Write-Host "Stopping Azure Functions host on port $FunctionsPort (PID $funcPid)..." -ForegroundColor Yellow
        Stop-Process -Id $funcPid -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped." -ForegroundColor Green

        if ($funcWrapperPid) {
            Stop-Process -Id $funcWrapperPid -Force -ErrorAction SilentlyContinue
            Write-Host "  Closed Functions terminal window." -ForegroundColor Green
        }
    }
    else {
        # App already stopped — close any orphaned wrapper window left behind
        $orphan = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -like '*func host start*' } |
            Select-Object -First 1
        if ($orphan) {
            Write-Host "Closing orphaned Functions terminal window..." -ForegroundColor Yellow
            Stop-Process -Id $orphan.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "  Closed." -ForegroundColor Green
        }
        else {
            Write-Host "Azure Functions host is not running on port $FunctionsPort." -ForegroundColor Gray
        }
    }

    # --- Azurite: find by its blob port ---
    $azuritePid = Get-PidOnPort $AzuriteBlobPort
    if ($azuritePid) {
        # Walk up the process tree (npx may sit between powershell and node) to find the wrapper
        $azuriteWrapperPid = $null
        $searchPid = $azuritePid
        for ($i = 0; $i -lt 3; $i++) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$searchPid" -ErrorAction SilentlyContinue
            if (-not $proc) { break }
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction SilentlyContinue
            if ($parent -and $parent.Name -eq 'powershell.exe' -and
                $parent.CommandLine -like '*azurite*' -and $parent.CommandLine -like "*$AzuriteBlobPort*") {
                $azuriteWrapperPid = $proc.ParentProcessId
                break
            }
            $searchPid = $proc.ParentProcessId
        }

        Write-Host "Stopping Azurite on port $AzuriteBlobPort (PID $azuritePid)..." -ForegroundColor Yellow
        Stop-Process -Id $azuritePid -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped." -ForegroundColor Green

        if ($azuriteWrapperPid) {
            Stop-Process -Id $azuriteWrapperPid -Force -ErrorAction SilentlyContinue
            Write-Host "  Closed Azurite terminal window." -ForegroundColor Green
        }
    }
    else {
        # App already stopped — close any orphaned wrapper window left behind
        $orphan = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -like '*azurite*' -and $_.CommandLine -like "*$AzuriteBlobPort*" } |
            Select-Object -First 1
        if ($orphan) {
            Write-Host "Closing orphaned Azurite terminal window..." -ForegroundColor Yellow
            Stop-Process -Id $orphan.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "  Closed." -ForegroundColor Green
        }
        else {
            Write-Host "Azurite is not running on port $AzuriteBlobPort." -ForegroundColor Gray
        }
    }

    Write-Host ""
}

function Release-Ports {
    Write-Section "Checking and Releasing Ports"
    $ports = @($FunctionsPort, $AzuriteBlobPort, $AzuriteQueuePort, $AzuriteTablePort)
    $failedPorts = @()

    foreach ($port in $ports) {
        $netstatLines = netstat -ano 2>$null | Select-String ":$port\s+" | Select-String "LISTENING"
        if ($netstatLines) {
            foreach ($line in $netstatLines) {
                $parts = $line -split '\s+' | Where-Object { $_ }
                if ($parts.Count -ge 5) {
                    $processId = $parts[-1]
                    Write-Host "Port $port is held by PID $processId. Forcing termination..." -ForegroundColor Yellow
                    & cmd /c "taskkill /F /PID $processId /T" 2>&1 | Out-Null
                    Start-Sleep -Milliseconds 500
                    Write-Host "  Attempting to close file handles..." -ForegroundColor Gray
                    & cmd /c "netsh int ipv4 set excludedportrange protocol=tcp startport=$port numberofports=1 store=persistent" 2>&1 | Out-Null
                    Start-Sleep -Milliseconds 500
                }
            }
        }

        Start-Sleep -Seconds 1
        $stillInUse = netstat -ano 2>$null | Select-String ":$port\s+" | Select-String "LISTENING"
        if ($stillInUse) {
            $failedPorts += $port
            Write-Host "Port $port is STILL IN USE" -ForegroundColor Red
        }
        else {
            Write-Host "Port $port is now free." -ForegroundColor Green
        }
    }

    if ($failedPorts.Count -gt 0) {
        Write-Host ""
        Write-Host "ERROR: The following ports could not be released: $($failedPorts -join ', ')" -ForegroundColor Red
        Write-Host ""
        Write-Host "SOLUTION: This typically requires administrator privileges." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Please follow these steps:" -ForegroundColor Yellow
        Write-Host "  1. Open a NEW PowerShell terminal with Administrator rights:" -ForegroundColor White
        Write-Host "     - Right-click PowerShell and select 'Run as administrator'" -ForegroundColor Gray
        Write-Host "  2. Navigate to the project directory:" -ForegroundColor White
        Write-Host "     cd '$projectRoot'" -ForegroundColor Gray
        Write-Host "  3. Run the start-app command again:" -ForegroundColor White
        Write-Host "     .\run.ps1 docker-stack start-app" -ForegroundColor Gray
        Write-Host ""
        exit 1
    }

    Write-Host "All required ports are available." -ForegroundColor Green
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

switch ($Command) {

    "help" {
        Show-Help
    }

    "start-app" {
        Stop-AppServices
        Release-Ports

        Write-Section "Clearing Cached Function Data"
        Remove-Item .Azure.Functions.CliCache -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item .funcignore -ErrorAction SilentlyContinue
        Write-Host "Cache cleared." -ForegroundColor Green
        Write-Host ""

        Write-Section "Clearing Log Files"
        Remove-Item .logs\*.log -Force -ErrorAction SilentlyContinue
        Write-Host "Log files cleared from .logs directory." -ForegroundColor Green
        Write-Host ""

        Write-Section "Configuring Environment: $Environment"
        & "$PSScriptRoot\configure-env.ps1" $Environment
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: configure-env.ps1 failed" -ForegroundColor Red
            exit 1
        }
        Write-Host ""

        Write-Section "Configuring Ports"
        $settingsPath = Join-Path $projectRoot "local.settings.json"
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $settings.Host.LocalHttpPort = $FunctionsPort
        #The keys and values used in the below connection string are publicly provided by Microsoft for Azurite development storage accounts. They are not secrets and are safe to include in public code.
        $settings.Values.AzureWebJobsStorage = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:$AzuriteBlobPort/devstoreaccount1;QueueEndpoint=http://127.0.0.1:$AzuriteQueuePort/devstoreaccount1;TableEndpoint=http://127.0.0.1:$AzuriteTablePort/devstoreaccount1;"

        $envVars = Read-EnvFile $EnvFile
        if ($Developer -eq "A") {
            $dbUser     = "developer_a"
            $dbName     = "developer_a_db"
            $dbPassword = $envVars["DEVELOPER_A_PASSWORD"]
        } else {
            $dbUser     = "developer_b"
            $dbName     = "developer_b_db"
            $dbPassword = $envVars["DEVELOPER_B_PASSWORD"]
        }
        if (-not $dbPassword) {
            Write-Host "WARNING: $($dbUser.ToUpper())_PASSWORD not found in .env - DATABASE_URL will be incomplete." -ForegroundColor Yellow
            Write-Host "  Add DEVELOPER_A_PASSWORD and DEVELOPER_B_PASSWORD to your .env file." -ForegroundColor Yellow
        }
        $settings.Values.DATABASE_URL = "postgresql://${dbUser}:${dbPassword}@localhost:5432/${dbName}"

        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath
        Write-Host "  Functions port : $FunctionsPort" -ForegroundColor Green
        Write-Host "  Azurite Blob   : $AzuriteBlobPort" -ForegroundColor Green
        Write-Host "  Azurite Queue  : $AzuriteQueuePort" -ForegroundColor Green
        Write-Host "  Azurite Table  : $AzuriteTablePort" -ForegroundColor Green
        Write-Host "  Database URL   : postgresql://${dbUser}:***@localhost:5432/${dbName}" -ForegroundColor Green
        Write-Host ""

        Write-Section "Installing Development Dependencies"
        Write-Host "Running: pip install -e '.[dev,local,db]'"
        Write-Host ""
        & "$projectRoot\venv\Scripts\pip.exe" install -e ".[dev,local,db]"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: pip install failed" -ForegroundColor Red
            exit 1
        }

        Write-Host ""
        Write-Host "Starting Azurite and Azure Functions in separate windows..."
        Write-Host ""

        Write-Host "Opening Azurite in new window..."
        Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$projectRoot'; npx azurite --silent --location .azurite --disableTelemetry --blobPort $AzuriteBlobPort --queuePort $AzuriteQueuePort --tablePort $AzuriteTablePort --skipApiVersionCheck"

        Start-Sleep -Seconds 3

        Write-Host "Opening Azure Functions host in new window..."
        Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd '$projectRoot'; venv\Scripts\activate; func host start"

        Write-Host ""
        Write-Host "Both services started in separate windows!"
        Write-Host "  Azurite Blob  : http://127.0.0.1:$AzuriteBlobPort"
        Write-Host "  Azurite Queue : http://127.0.0.1:$AzuriteQueuePort"
        Write-Host "  Azurite Table : http://127.0.0.1:$AzuriteTablePort"
        Write-Host "  Function      : http://localhost:$FunctionsPort/api/logging"
        Write-Host ""
    }

    "stop-app" {
        Stop-AppServices
    }

    "start-azurite" {
        Write-Section "Starting Azurite Storage Emulator"
        Write-Host "Azurite is starting with disk-based storage at .\.azurite"
        Write-Host "Available at:"
        Write-Host "  - Blob:  http://127.0.0.1:$AzuriteBlobPort"
        Write-Host "  - Queue: http://127.0.0.1:$AzuriteQueuePort"
        Write-Host "  - Table: http://127.0.0.1:$AzuriteTablePort"
        Write-Host ""
        npx azurite --silent --location .azurite --disableTelemetry --blobPort $AzuriteBlobPort --queuePort $AzuriteQueuePort --tablePort $AzuriteTablePort --skipApiVersionCheck
    }

    "start-functions" {
        Write-Section "Starting Azure Functions Host"
        Write-Host "Function will be available at: http://localhost:7071/api/logging"
        Write-Host ""
        func host start
    }

    "test-endpoint" {
        Write-Section "Testing Logging Endpoint"
        Write-Host "Sending GET request to http://localhost:$FunctionsPort/api/logging"
        Write-Host ""
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$FunctionsPort/api/logging" -UseBasicParsing
            Write-Host "Status Code: $($response.StatusCode)" -ForegroundColor Green
            Write-Host "Response Body:" -ForegroundColor Cyan
            Write-Host $response.Content
            Write-Host ""
        }
        catch {
            Write-Host "ERROR: Request failed" -ForegroundColor Red
            Write-Host $_.Exception.Message
            Write-Host ""
            Write-Host "Make sure the Azure Functions host is running with: .\run.ps1 docker-stack start-app -FunctionsPort $FunctionsPort" -ForegroundColor Yellow
        }
    }
}
