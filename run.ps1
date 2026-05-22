<#
.SYNOPSIS
    Entry point for all project scripts.

    You need to have your PowerShell Profiles configured to run "ods" commands from the PowerShell terminal and the VS Code terminal.
    See docs/powershell.md for setup instructions.

.DESCRIPTION
    Dispatches to scripts in the scripts\ directory, passing all remaining
    arguments through unchanged. This allows all project scripts to live in
    scripts\ while still being invoked from the project root.

    Available scripts:
        configure-env   Switch local.settings.json between environment templates.
        docker-stack    Manage the Docker observability stack and app services.
        migrate         Run Alembic database migrations.
        quality         Run code quality checks and tests.
        seed-storage    Manage ETL blob storage in Azurite.

.EXAMPLE
    .\run.ps1 quality -All
    .\run.ps1 quality -Ruff -Tests
    .\run.ps1 docker-stack start
    .\run.ps1 docker-stack start-app -Developer A
    .\run.ps1 docker-stack stop
    .\run.ps1 configure-env local
    .\run.ps1 configure-env azure
    .\run.ps1 migrate upgrade -Developer A
    .\run.ps1 migrate history
    .\run.ps1 seed-storage seed -Developer A
    .\run.ps1 seed-storage list -Developer A
#>

# Do not use a param() block. Using $args directly is the only reliable way to
# forward switch parameters (e.g. -All, -Ruff) to the target script unchanged.
# A param() block with ValueFromRemainingArguments captures switches as strings,
# which can cause them to bind to the wrong parameter in the target script.

if ($args.Count -eq 0 -or $args[0] -eq "help") {
    Write-Host @"
================================================================================
     ODS Sample Function Project - Script Runner
================================================================================

USAGE:
    .\run.ps1 <script> [arguments]
    .\run.ps1 help

AVAILABLE SCRIPTS:
    configure-env   Switch local.settings.json between environment templates.
                    .\run.ps1 configure-env local
                    .\run.ps1 configure-env azure

    dock            Manage the Docker observability stack in Rancher.
                    docker-stack    (alias: dock)
                    .\run.ps1 dock start
                    .\run.ps1 dock stop
                    .\run.ps1 dock status
                    .\run.ps1 dock logs loki

    apps            Manage the local Azure Function and Azurite services.
                    .\run.ps1 apps start-app -Developer A

    migrate         Run Alembic database migrations.
                    .\run.ps1 migrate upgrade -Developer A
                    .\run.ps1 migrate downgrade -Developer A
                    .\run.ps1 migrate history
                    .\run.ps1 migrate revision -Message "add column"

    quality         Run code quality checks and tests.
                    .\run.ps1 quality -All
                    .\run.ps1 quality -Ruff -Tests
                    .\run.ps1 quality -Coverage

    seed-storage    Manage ETL blob storage in Azurite.
                    .\run.ps1 seed-storage seed -Developer A
                    .\run.ps1 seed-storage list -Developer A
                    .\run.ps1 seed-storage clear -Developer A

TIP:
    Pass 'help' to any script for its full usage details:
        .\run.ps1 apps help
        .\run.ps1 dock help
        .\run.ps1 migrate help
        .\run.ps1 quality -Help
        .\run.ps1 seed-storage help
"@
    exit 0
}

# Aliases — map friendly names to their script filenames.
$aliases = @{
    "dock" = "docker-stack"
}

$scriptName = $args[0]
if ($aliases.ContainsKey($scriptName)) {
    $scriptName = $aliases[$scriptName]
}

$target = Join-Path $PSScriptRoot "scripts\$scriptName.ps1"

if (-not (Test-Path $target)) {
    $available = (Get-ChildItem "$PSScriptRoot\scripts\*.ps1").BaseName -join ', '
    Write-Error "Unknown script '$scriptName'. Available: $available"
    exit 1
}

if ($args.Count -gt 1) {
    $forwardArgs = $args[1..($args.Count - 1)]
    & $target @forwardArgs
} else {
    & $target
}