<#
.SYNOPSIS
    Manage ETL ingestion blob storage in Azurite for local development.

.DESCRIPTION
    Provides commands to seed, inspect, download, and clean blobs in the
    local Azurite storage emulator. All commands target the configured
    container and blob prefix.

    Prerequisites:
      1. Azurite must be running:
             .\run.ps1 apps start-app -Developer <A|B>
             or
             ods apps start-app -Developer <A|B>
      2. Azure CLI must be installed:
             winget install Microsoft.AzureCLI
         Restart your terminal after installation.

.PARAMETER Command
    seed         Create the container and queue, upload .dat/.sum files from
                 data/, then send one queue message per batch to etl-ingest-queue.
                 Default when no command is supplied.
    list         List all blobs under the container/prefix.
    containers   List all containers in the storage account.
    show         Show properties of a specific blob (-BlobName required).
    download     Download a blob and print its contents (-BlobName required).
    delete       Delete a specific blob (-BlobName required).
    clear        Delete all blobs under the container/prefix.
    help         Show this help message.

.PARAMETER Developer
    Developer A or B. Selects the Azurite port bundle to target.
      A   blob 10000  queue 10001
      B   blob 10010  queue 10011

.PARAMETER Container
    Blob container name. Default: etl-ingest.

.PARAMETER BlobPrefix
    Virtual folder prefix inside the container. Default: party.

.PARAMETER QueueName
    Storage queue that receives a message for each uploaded batch.
    Default: etl-ingest-queue.

.PARAMETER BlobName
    Full blob name (including prefix) for show, download, and delete commands.
    Example: party/party_load_20260401.dat

.EXAMPLE
    .\run.ps1 seed-storage help
    .\run.ps1 seed-storage -Developer A
    .\run.ps1 seed-storage seed -Developer A
    .\run.ps1 seed-storage list -Developer A
    .\run.ps1 seed-storage containers -Developer A
    .\run.ps1 seed-storage show -Developer A -BlobName party/party_load_20260401.dat
    .\run.ps1 seed-storage download -Developer A -BlobName party/party_load_20260401.sum
    .\run.ps1 seed-storage delete -Developer A -BlobName party/party_load_20260401.dat
    .\run.ps1 seed-storage clear -Developer A
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet("seed", "list", "containers", "show", "download", "delete", "clear", "help")]
    [string]$Command = "seed",

    [ValidateSet("A", "B")]
    [string]$Developer = "",

    [string]$Container = "etl-ingest",

    [string]$BlobPrefix = "party",

    [string]$QueueName = "etl-ingest-queue",

    [string]$BlobName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
}

function Show-Help {
    Write-Host @"
================================================================================
     ODS Storage Manager
================================================================================

USAGE:
    .\run.ps1 seed-storage [command] [options]

COMMANDS:
    seed         Create container + queue, upload .dat/.sum from data/,
                 then enqueue one message per batch to etl-ingest-queue.
                 Default when no command is given.
    list         List all blobs under -Container/-BlobPrefix.
    containers   List all containers in the storage account.
    show         Show properties of a specific blob.
    download     Download a blob and print its contents to the terminal.
    delete       Delete a specific blob.
    clear        Delete all blobs under -Container/-BlobPrefix.
    help         Show this help message.

OPTIONS:
    -Developer <A|B>        Target Azurite port bundle. Prompted if omitted.
                              A   blob 10000  queue 10001
                              B   blob 10010  queue 10011
    -Container <name>       Blob container name. Default: etl-ingest.
    -BlobPrefix <prefix>    Virtual folder prefix. Default: party.
    -QueueName <name>       Trigger queue name. Default: etl-ingest-queue.
    -BlobName <name>        Full blob name for show, download, delete.
                            Example: party/party_load_20260401.dat

EXAMPLES:
    .\run.ps1 seed-storage help
    .\run.ps1 seed-storage -Developer A
    .\run.ps1 seed-storage seed -Developer A
    .\run.ps1 seed-storage list -Developer A
    .\run.ps1 seed-storage containers -Developer A
    .\run.ps1 seed-storage show -Developer A -BlobName party/party_load_20260401.dat
    .\run.ps1 seed-storage download -Developer A -BlobName party/party_load_20260401.sum
    .\run.ps1 seed-storage delete -Developer A -BlobName party/party_load_20260401.dat
    .\run.ps1 seed-storage clear -Developer A

PREREQUISITES:
    1. Azurite must be running:
           .\run.ps1 docker-stack start-app -Developer <A|B>
    2. Azure CLI must be installed:
           winget install Microsoft.AzureCLI
"@
}

# ---------------------------------------------------------------------------
# Help - handle before any prompts or checks
# ---------------------------------------------------------------------------

if ($Command -eq "help") {
    Show-Help
    exit 0
}

# ---------------------------------------------------------------------------
# Validate BlobName is supplied for commands that require it
# ---------------------------------------------------------------------------

if ($Command -in @("show", "download", "delete") -and $BlobName -eq "") {
    Write-Host "ERROR: -BlobName is required for the '$Command' command." -ForegroundColor Red
    Write-Host "Example: .\run.ps1 seed-storage $Command -Developer A -BlobName party/party_load_20260401.dat" -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# Port resolution
# ---------------------------------------------------------------------------

if ($Developer -eq "") {
    do {
        $Developer = Read-Host "Developer (A or B)"
    } while ($Developer -notin @("A", "B"))
}

$BlobPort  = if ($Developer -eq "A") { 10000 } else { 10010 }
$QueuePort = if ($Developer -eq "A") { 10001 } else { 10011 }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

Write-Section "Checking Prerequisites"

# Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Azure CLI (az) is not installed or not on PATH." -ForegroundColor Red
    Write-Host ""
    Write-Host "Install it with:" -ForegroundColor Yellow
    Write-Host "    winget install Microsoft.AzureCLI" -ForegroundColor White
    Write-Host ""
    Write-Host "Then restart your terminal and run this script again." -ForegroundColor Yellow
    exit 1
}
$azVersion = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
Write-Host "Azure CLI $azVersion found." -ForegroundColor Green

# Azurite version (resolved via npx - no PATH entry required).
# NODE_NO_WARNINGS suppresses npm's CommonJS/ESM compatibility warnings that
# newer Node versions emit to stderr, which ErrorActionPreference=Stop would
# otherwise turn into a terminating error.
$env:NODE_NO_WARNINGS = "1"
$azuriteVersion = npx azurite --version 2>$null
$env:NODE_NO_WARNINGS = $null
Write-Host "Azurite $azuriteVersion found." -ForegroundColor Green

# Azurite reachability - any HTTP response (including 400/403) means it is up.
Write-Host "Checking Azurite on port $BlobPort..."
$azuriteUp = $false
try {
    # Test simple root endpoint - any response means Azurite is up
    $response = Invoke-WebRequest `
        -Uri "http://127.0.0.1:$BlobPort/" `
        -UseBasicParsing `
        -TimeoutSec 3 `
        -ErrorAction SilentlyContinue
    # If we get here, the connection succeeded (any HTTP status means Azurite responded)
    $azuriteUp = $true
}
catch {
    # Connection failed
}

# If first check failed, try a simple TCP connection as last resort
if (-not $azuriteUp) {
    try {
        $tcpClient = [System.Net.Sockets.TcpClient]::new()
        $tcpClient.Connect("127.0.0.1", $BlobPort)
        if ($tcpClient.Connected) {
            $azuriteUp = $true
        }
        $tcpClient.Close()
    }
    catch {
        # Still not reachable
    }
}

if (-not $azuriteUp) {
    Write-Host "ERROR: Azurite is not reachable on port $BlobPort." -ForegroundColor Red
    Write-Host ""
    Write-Host "Start it first:" -ForegroundColor Yellow
    Write-Host "    .\run.ps1 apps start-app -Developer $Developer" -ForegroundColor White
    Write-Host "or" -ForegroundColor Yellow
    Write-Host "    .\run.ps1 apps start-azurite -Developer $Developer" -ForegroundColor White
    exit 1
}
Write-Host "Azurite is running on port $BlobPort." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Connection string
# ---------------------------------------------------------------------------

$connectionString =
    "DefaultEndpointsProtocol=http;" +
    "AccountName=devstoreaccount1;" +
    "AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;" +
    "BlobEndpoint=http://127.0.0.1:$BlobPort/devstoreaccount1;" +
    "QueueEndpoint=http://127.0.0.1:$QueuePort/devstoreaccount1;"

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

switch ($Command) {

    "seed" {
        $DataDir = Join-Path $projectRoot "data"
        $filesToUpload = Get-ChildItem -Path $DataDir -File |
            Where-Object { $_.Extension -in @(".dat", ".sum") }

        if ($filesToUpload.Count -eq 0) {
            Write-Host "ERROR: No .dat or .sum files found in $DataDir" -ForegroundColor Red
            exit 1
        }
        Write-Host "$($filesToUpload.Count) file(s) found in data/ for upload." -ForegroundColor Green

        Write-Section "Container: $Container"
        az storage container create `
            --name $Container `
            --connection-string $connectionString `
            --output none
        Write-Host "Container '$Container' is ready." -ForegroundColor Green

        Write-Section "Queue: $QueueName"
        az storage queue create `
            --name $QueueName `
            --connection-string $connectionString `
            --output none
        Write-Host "Queue '$QueueName' is ready." -ForegroundColor Green

        Write-Section "Uploading Files -> $Container/$BlobPrefix/"
        foreach ($file in $filesToUpload) {
            $blobName = "$BlobPrefix/$($file.Name)"
            Write-Host "  $($file.Name)" -NoNewline
            Write-Host "  ->  $Container/$blobName" -ForegroundColor DarkGray
            az storage blob upload `
                --container-name $Container `
                --file $file.FullName `
                --name $blobName `
                --connection-string $connectionString `
                --overwrite `
                --output none
            Write-Host "  OK" -ForegroundColor Green
        }

        # ---- Enqueue one message per batch (matched .dat + .sum pair) -------
        #
        # Azurite does not support Azure Event Grid, so it cannot emit blob
        # events automatically. This block replicates what an Event Grid
        # subscription would do in production: after all files are committed,
        # send a single JSON message per batch to the trigger queue.
        #
        # The message is base64-encoded because the Azure Functions Queue
        # trigger runtime expects base64-encoded message bodies.
        #
        Write-Section "Enqueueing Batch Messages -> $QueueName"

        $batches = $filesToUpload |
            Group-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }

        foreach ($batch in $batches) {
            $batchId  = $batch.Name
            $datFile  = $batch.Group | Where-Object { $_.Extension -eq ".dat" } | Select-Object -First 1
            $sumFile  = $batch.Group | Where-Object { $_.Extension -eq ".sum" } | Select-Object -First 1

            if (-not $datFile -or -not $sumFile) {
                Write-Host "  Skipping $batchId - missing .dat or .sum" -ForegroundColor Yellow
                continue
            }

            $payload = [ordered]@{
                batch_id    = $batchId
                container   = $Container
                blob_prefix = $BlobPrefix
                dat_blob    = "$BlobPrefix/$($datFile.Name)"
                sum_blob    = "$BlobPrefix/$($sumFile.Name)"
            } | ConvertTo-Json -Compress

            $payloadBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($payload)
            )

            az storage message put `
                --queue-name $QueueName `
                --content $payloadBase64 `
                --connection-string $connectionString `
                --output none

            Write-Host "  Queued: $batchId" -ForegroundColor Green
        }

        Write-Section "Blobs in $Container/$BlobPrefix/"
        az storage blob list `
            --container-name $Container `
            --prefix $BlobPrefix `
            --connection-string $connectionString `
            --query "[].{Blob:name, Bytes:properties.contentLength, LastModified:properties.lastModified}" `
            --output table

        Write-Host ""
        Write-Host "Base URL:" -ForegroundColor Cyan
        Write-Host "  http://127.0.0.1:$BlobPort/devstoreaccount1/$Container/$BlobPrefix/" -ForegroundColor White
        Write-Host ""
    }

    "list" {
        Write-Section "Blobs in $Container/$BlobPrefix/"
        az storage blob list `
            --container-name $Container `
            --prefix $BlobPrefix `
            --connection-string $connectionString `
            --query "[].{Blob:name, Bytes:properties.contentLength, LastModified:properties.lastModified}" `
            --output table
        Write-Host ""
    }

    "containers" {
        Write-Section "Containers in devstoreaccount1"
        az storage container list `
            --connection-string $connectionString `
            --query "[].{Container:name, LastModified:properties.lastModified}" `
            --output table
        Write-Host ""
    }

    "show" {
        Write-Section "Blob Properties: $BlobName"
        az storage blob show `
            --container-name $Container `
            --name $BlobName `
            --connection-string $connectionString `
            --output table
        Write-Host ""
    }

    "download" {
        Write-Section "Downloading: $BlobName"
        $tempFile = Join-Path $env:TEMP ("azurite-download-" + [System.IO.Path]::GetFileName($BlobName))
        az storage blob download `
            --container-name $Container `
            --name $BlobName `
            --file $tempFile `
            --connection-string $connectionString `
            --output none
        Write-Host "Contents of $BlobName :" -ForegroundColor Cyan
        Write-Host ""
        Get-Content $tempFile
        Write-Host ""
        Remove-Item $tempFile -Force
    }

    "delete" {
        Write-Section "Deleting: $Container/$BlobName"
        az storage blob delete `
            --container-name $Container `
            --name $BlobName `
            --connection-string $connectionString `
            --output none
        Write-Host "Deleted '$BlobName'." -ForegroundColor Green
        Write-Host ""
        Write-Section "Remaining blobs in $Container/$BlobPrefix/"
        az storage blob list `
            --container-name $Container `
            --prefix $BlobPrefix `
            --connection-string $connectionString `
            --query "[].{Blob:name, Bytes:properties.contentLength, LastModified:properties.lastModified}" `
            --output table
        Write-Host ""
    }

    "clear" {
        Write-Section "Clearing all blobs in $Container/$BlobPrefix/"

        $blobs = az storage blob list `
            --container-name $Container `
            --prefix $BlobPrefix `
            --connection-string $connectionString `
            --query "[].name" `
            --output tsv

        if (-not $blobs) {
            Write-Host "No blobs found under '$BlobPrefix/' - nothing to clear." -ForegroundColor Yellow
            exit 0
        }

        foreach ($blob in $blobs) {
            Write-Host "  Deleting $blob..." -NoNewline
            az storage blob delete `
                --container-name $Container `
                --name $blob `
                --connection-string $connectionString `
                --output none
            Write-Host " OK" -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "All blobs under '$Container/$BlobPrefix/' deleted." -ForegroundColor Green
        Write-Host ""
    }
}
