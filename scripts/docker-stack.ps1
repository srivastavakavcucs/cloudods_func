<#
.SYNOPSIS
    Manage the local observability and PostgreSQL database Docker stack.

.DESCRIPTION
    Wraps docker compose commands for the full-stack profile for local development.

    All Docker services use pre-built public images -- there are no Dockerfiles in
    this project. 'rebuild' means pull the latest image and force-recreate the
    container rather than compiling a Dockerfile.

    Volume notes:
      Named volumes (jaeger-data, prometheus-data, loki-data, grafana-data, postgres-data) live entirely in
      Docker's volume store. There is NO local filesystem data directory to clean.
      Config files in docker/ are bind-mounted read-only into their containers.
      The .logs directory is bind-mounted read-only into promtail only.
      'reset' removes the three named volumes -- that is the only cleanup needed
      for a fully clean restart.

    Docker services (full-stack profile):
      otel-collector   Receives OTLP signals; routes to Jaeger / Prometheus / Loki
      jaeger           Distributed trace UI  -- http://localhost:16686
      prometheus       Metrics storage       -- http://localhost:9090
      loki             Log aggregation       -- http://localhost:3100
      grafana          Unified dashboards    -- http://localhost:3000
      dozzle           Container log viewer  -- http://localhost:8080

.PARAMETER Command
    Docker stack commands:
      start        Start the stack or a single Docker service.
      stop         Stop and remove containers. Named volumes are preserved.
      restart      Restart without recreating (does not pull new images).
      rebuild      Pull the latest image and force-recreate.
                   Safe to run on a single service -- other containers keep running.
      reset        Full teardown: stop all containers AND delete named volumes.
                   Prompts for confirmation. Use when you need a clean slate.
      logs         Follow log output. Press Ctrl+C to stop.
      status       Show container status and health.

.PARAMETER Service
    Optional. Name of a single Docker service to target. When omitted the command
    applies to every service in the active stack profile.
    Not applicable to application commands.

.PARAMETER Environment
    Environment to configure when using start-app: local | azure. Default: local.

.EXAMPLE
    .\run.ps1 docker-stack start
    .\run.ps1 docker-stack start loki
    .\run.ps1 docker-stack stop
    .\run.ps1 docker-stack restart otel-collector
    .\run.ps1 docker-stack rebuild
    .\run.ps1 docker-stack rebuild loki
    .\run.ps1 docker-stack reset
    .\run.ps1 docker-stack purge
    .\run.ps1 docker-stack logs loki
    .\run.ps1 docker-stack status
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet("help", "start", "stop", "restart", "rebuild", "reset", "purge", "logs", "status", "restart-grafana")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Service = "",

    [string]$Stack = "full-stack",

    [ValidateSet("local", "azure")]
    [string]$Environment = "local"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot

$ComposeFile = Join-Path $projectRoot "docker\docker-compose.yml"
$EnvFile     = Join-Path $projectRoot ".env"

# Named volumes created by this compose project (prefix = compose project name
# declared as 'name: ods' in docker-compose.yml).
# These live in Docker's volume store -- there is no corresponding local directory.
$NamedVolumes = @(
    "ods_jaeger-data",
    "ods_loki-data",
    "ods_prometheus-data",
    "ods_grafana-data",
    "ods_postgres-data"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-Compose {
    param([string[]]$ExtraArgs)
    $allArgs = @("compose", "-f", $ComposeFile, "--env-file", $EnvFile, "--profile", $Stack) + $ExtraArgs
    Write-Host "  docker $($allArgs -join ' ')" -ForegroundColor DarkGray
    & docker @allArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Write-Step {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Remove-NamedVolumes {
    Write-Step "Removing named volumes..."
    foreach ($vol in $NamedVolumes) {
        # Temporarily suppress Stop behaviour so a missing volume is handled
        # gracefully rather than throwing a terminating NativeCommandError.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $null = & docker volume rm $vol 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prev

        if ($exitCode -eq 0) {
            Write-Host "  Removed $vol" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  $vol not found - skipping" -ForegroundColor DarkGray
        }
    }
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
     ODS Docker Stack Manager
================================================================================

USAGE:
    .\run.ps1 docker-stack <command> [options]

DOCKER STACK COMMANDS:
    help             Show this help message
    start            Start the full stack, or a single service
    stop             Stop containers (named volumes are preserved)
    restart          Restart without pulling new images
    rebuild          Pull latest images and force-recreate containers
    reset            Full teardown including named volumes, then restart (prompts)
    purge            Remove ALL containers and volumes. Does not restart (prompts)
    logs             Follow log output (Ctrl+C to stop)
    status           Show container status and health

OPTIONS:
    -Service <name>      Target a single Docker service (e.g. loki, grafana)
    -Environment <env>   Settings environment for start-app: local | azure
                         Default: local

EXAMPLES:
    .\run.ps1 docker-stack help
    .\run.ps1 docker-stack start
    .\run.ps1 docker-stack start loki
    .\run.ps1 docker-stack logs loki
    .\run.ps1 docker-stack rebuild
    .\run.ps1 docker-stack reset
    .\run.ps1 docker-stack purge

SERVICE URLS (full-stack profile):
    Grafana    http://localhost:3000
    Jaeger     http://localhost:16686
    Prometheus http://localhost:9090
    Loki API   http://localhost:3100
    Dozzle     http://localhost:8080
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

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

switch ($Command) {

    "help" {
        Show-Help
    }

    "start" {
        if ($Service) {
            Write-Step "Starting service '$Service'..."
            Invoke-Compose @("up", "-d", $Service)
        }
        else {
            Write-Step "Starting $Stack stack..."
            Invoke-Compose @("up", "-d")
        }
    }

    "stop" {
        if ($Service) {
            Write-Step "Stopping service '$Service'..."
            Invoke-Compose @("stop", $Service)
        }
        else {
            Write-Step "Stopping $Stack stack (named volumes preserved)..."
            Invoke-Compose @("down")
        }
    }

    "restart" {
        if ($Service) {
            Write-Step "Restarting service '$Service'..."
            Invoke-Compose @("restart", $Service)
        }
        else {
            Write-Step "Restarting $Stack stack..."
            Invoke-Compose @("restart")
        }
    }

    "rebuild" {
        # Pull the latest image then force-recreate so any config file changes
        # are picked up. When targeting a single service, other containers keep
        # running and are not affected.
        if ($Service) {
            Write-Step "Pulling latest image for '$Service'..."
            Invoke-Compose @("pull", $Service)
            Write-Step "Recreating '$Service'..."
            Invoke-Compose @("up", "-d", "--force-recreate", $Service)
        }
        else {
            Write-Step "Pulling latest images for $Stack stack..."
            Invoke-Compose @("pull")
            Write-Step "Recreating $Stack stack..."
            Invoke-Compose @("up", "-d", "--force-recreate")
        }
    }

    "reset" {
        Write-Host ""
        Write-Host "This will stop all containers and DELETE the following named volumes:" -ForegroundColor Yellow
        Write-Host "(There is no local data directory - only these Docker-managed volumes exist.)" -ForegroundColor DarkGray
        foreach ($vol in $NamedVolumes) {
            Write-Host "  $vol" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "Stored metrics, logs, and Grafana state will be permanently lost." -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host "Type 'yes' to continue"
        if ($confirm -ne "yes") {
            Write-Host "Cancelled." -ForegroundColor DarkGray
            exit 0
        }

        Write-Step "Stopping and removing containers..."
        Invoke-Compose @("down")

        Remove-NamedVolumes

        Write-Host ""
        Write-Step "Starting fresh $Stack stack..."
        Invoke-Compose @("up", "-d")
    }

    "purge" {
        Write-Host ""
        Write-Host "WARNING: This will remove ALL containers and volumes for this project." -ForegroundColor Red
        Write-Host "The following named volumes will be permanently deleted:" -ForegroundColor Yellow
        foreach ($vol in $NamedVolumes) {
            Write-Host "  $vol" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "All stored metrics, logs, traces, and Grafana state will be lost." -ForegroundColor Yellow
        Write-Host "The stack will NOT be restarted. Run 'start' when ready." -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host "Type 'yes' to continue"
        if ($confirm -ne "yes") {
            Write-Host "Cancelled." -ForegroundColor DarkGray
            exit 0
        }

        Write-Step "Stopping and removing all containers..."
        Invoke-Compose @("down", "--volumes", "--remove-orphans")

        Remove-NamedVolumes

        Write-Host ""
        Write-Host "Purge complete. Run '.\run.ps1 apps start' to bring the stack back up." -ForegroundColor Green
    }

    "logs" {
        if ($Service) {
            Invoke-Compose @("logs", "-f", "--tail", "100", $Service)
        }
        else {
            Invoke-Compose @("logs", "-f", "--tail", "100")
        }
    }

    "status" {
        Invoke-Compose @("ps")
    }

    "restart-grafana" {
        Write-Step "Restarting Grafana container..."
        Invoke-Compose @("restart", "grafana")
    }
}
