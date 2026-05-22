<#
.SYNOPSIS
    Switch the active Azure Functions local settings to a named environment.

.DESCRIPTION
    Copies one of the committed settings templates to local.settings.json,
    which is the file the Azure Functions runtime reads locally.
    local.settings.json is gitignored and should never be committed directly.

    Available environments:
        local   Uses TELEMETRY_TARGET=local and LOGGING_TARGET=local.
                Exports telemetry and logs to the local Docker stack
                (OTel Collector -> Jaeger / Prometheus / Loki / Grafana).
                Requires: pip install -e ".[local]"
                Requires: docker compose --profile full-stack up -d

        azure   Uses TELEMETRY_TARGET=azure and LOGGING_TARGET=azure.
                Exports telemetry and logs to Azure Monitor / App Insights.
                Requires: pip install -e ".[azure]"
                Requires: APPLICATIONINSIGHTS_CONNECTION_STRING to be filled in
                          after switching (see ACTION REQUIRED message below).

    NOTE: LOGGING_TARGET and TELEMETRY_TARGET are independent settings.
    After switching, you can edit local.settings.json to mix targets
    (e.g. TELEMETRY_TARGET=azure with LOGGING_TARGET=local) if needed.

.PARAMETER Target
    The environment to activate: 'local' or 'azure'.

.EXAMPLE
    .\run.ps1 configure-env local
    .\run.ps1 configure-env azure
#>
param(
    [Parameter(Mandatory, Position = 0, HelpMessage = "Target environment: local or azure")]
    [ValidateSet("local", "azure")]
    [string]$Target
)

$projectRoot = Split-Path -Parent $PSScriptRoot

$template = Join-Path $projectRoot "local.settings.$Target.json"
$destination = Join-Path $projectRoot "local.settings.json"

if (-not (Test-Path $template)) {
    Write-Error "Settings template not found: $template"
    exit 1
}

if (Test-Path $destination) {
    Write-Host "Overwriting existing $destination." -ForegroundColor DarkGray
}

Copy-Item $template $destination -Force
Write-Host "Active settings switched to '$Target'." -ForegroundColor Green
Write-Host ""

# Resolve pip from the project venv, falling back to the PATH.
$pip = Join-Path $projectRoot "venv\Scripts\pip.exe"
if (-not (Test-Path $pip)) {
    $pip = "pip"
}

if ($Target -eq "local") {
    Write-Host "Installing local extra (OTLP exporter)..." -ForegroundColor Cyan
    & $pip install -e ".[local]"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: pip install failed." -ForegroundColor Red
        exit 1
    }
}

if ($Target -eq "azure") {
    Write-Host "Installing azure extra (Azure Monitor exporter)..." -ForegroundColor Cyan
    & $pip install -e ".[azure]"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: pip install failed." -ForegroundColor Red
        exit 1
    }
    Write-Host ""
    Write-Host "ACTION REQUIRED:" -ForegroundColor Yellow
    Write-Host "  Open local.settings.json and replace the placeholder value:" -ForegroundColor Yellow
    Write-Host "      APPLICATIONINSIGHTS_CONNECTION_STRING" -ForegroundColor White
    Write-Host "  with your actual connection string from the Azure portal." -ForegroundColor Yellow
}
