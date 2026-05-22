<#
.SYNOPSIS
    Run Alembic migrations against a developer's database.

.DESCRIPTION
    Prompts for Developer A or B, builds the correct DATABASE_URL from .env,
    and runs the requested Alembic command against that developer's database
    using their own credentials.

    Developer databases and credentials:
      A   developer_a user  ->  developer_a_db
      B   developer_b user  ->  developer_b_db

    Commands that connect to the database (prompt for Developer):
      upgrade      Apply pending migrations. Default target: head.
      downgrade    Roll back migrations. Default target: -1.
      current      Show the current applied revision.

    Commands that do not connect to the database:
      history      List all migrations and their dependencies.
      revision     Generate a new empty migration file.
      help         Show this help message.

.PARAMETER Command
    The Alembic command to run. Default: upgrade.

.PARAMETER Developer
    Developer A or B. Prompted if not provided for database commands.

.PARAMETER Target
    Revision target for upgrade or downgrade.
    upgrade   defaults to 'head'  (apply all pending)
    downgrade defaults to '-1'    (roll back one step)
    Examples: head, base, +1, -1, 0001

.PARAMETER Message
    Description for the 'revision' command. Prompted if not provided.

.EXAMPLE
    .\run.ps1 migrate
    .\run.ps1 migrate help
    .\run.ps1 migrate upgrade -Developer A
    .\run.ps1 migrate upgrade -Developer B -Target 0001
    .\run.ps1 migrate downgrade -Developer A
    .\run.ps1 migrate downgrade -Developer B -Target base
    .\run.ps1 migrate current -Developer A
    .\run.ps1 migrate history
    .\run.ps1 migrate revision -Message "add email to party"
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet("help", "upgrade", "downgrade", "current", "history", "revision")]
    [string]$Command = "help",

    [ValidateSet("A", "B")]
    [string]$Developer = "",

    [string]$Target = "",

    [string]$Message = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot

$EnvFile  = Join-Path $projectRoot ".env"
$Alembic  = Join-Path $projectRoot "venv\Scripts\alembic.exe"

# Commands that require a live database connection.
$dbCommands = @("upgrade", "downgrade", "current")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

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
     ODS Alembic Migration Runner
================================================================================

USAGE:
    .\run.ps1 migrate [command] [options]

COMMANDS (database):
    upgrade      Apply pending migrations to the developer's database
                 Default target: head (all pending)
    downgrade    Roll back migrations from the developer's database
                 Default target: -1 (one step back)
    current      Show the current applied revision for the developer's database

COMMANDS (local):
    history      List all migrations and their dependencies (no DB needed)
    revision     Generate a new empty migration file (no DB needed)
    help         Show this help message

OPTIONS:
    -Developer <A|B>   Target developer database. Prompted if omitted on
                       database commands.
    -Target <rev>      Revision target for upgrade/downgrade.
                       Examples: head, base, +1, -1, 0001
    -Message <text>    Description for the 'revision' command.
                       Prompted if omitted.

DEVELOPER DATABASES:
    A   developer_a  ->  developer_a_db  (credentials from DEVELOPER_A_PASSWORD in .env)
    B   developer_b  ->  developer_b_db  (credentials from DEVELOPER_B_PASSWORD in .env)

EXAMPLES:
    .\run.ps1 migrate help
    .\run.ps1 migrate upgrade -Developer A
    .\run.ps1 migrate upgrade -Developer B -Target 0001
    .\run.ps1 migrate downgrade -Developer A
    .\run.ps1 migrate downgrade -Developer B -Target base
    .\run.ps1 migrate current -Developer A
    .\run.ps1 migrate history
    .\run.ps1 migrate revision -Message "add email to party"
"@
}

function Read-EnvFile {
    <#
    .SYNOPSIS
        Parse the project .env file into a hashtable.
    .DESCRIPTION
        Reads key=value pairs from .env, ignoring blank lines and comments.
        Returns a hashtable of variable names to their string values.
    #>
    $vars = @{}
    if (-not (Test-Path $EnvFile)) {
        Write-Host "WARNING: .env file not found at $EnvFile" -ForegroundColor Yellow
        return $vars
    }
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^([^#=]+)=(.*)$') {
            $vars[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $vars
}

function Invoke-Alembic {
    <#
    .SYNOPSIS
        Run an Alembic command via the project virtual environment.
    .DESCRIPTION
        Resolves alembic from the project venv rather than relying on PATH,
        so the correct dependencies and alembic.ini are always used.
        Exits with Alembic's exit code on failure.
    #>
    param([string[]]$AlembicArgs)
    Write-Host "  alembic $($AlembicArgs -join ' ')" -ForegroundColor DarkGray
    & $Alembic @AlembicArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# ---------------------------------------------------------------------------
# Developer prompt and DATABASE_URL setup
# ---------------------------------------------------------------------------

if ($Developer -eq "" -and $Command -in $dbCommands) {
    do {
        $Developer = Read-Host "Developer (A or B)"
    } while ($Developer -notin @("A", "B"))
}

$dbName = ""

if ($Developer -ne "") {
    $envVars = Read-EnvFile

    if ($Developer -eq "A") {
        $dbUser    = "developer_a"
        $dbName    = "developer_a_db"
        $dbPass    = $envVars["DEVELOPER_A_PASSWORD"]
    } else {
        $dbUser    = "developer_b"
        $dbName    = "developer_b_db"
        $dbPass    = $envVars["DEVELOPER_B_PASSWORD"]
    }

    if (-not $dbPass) {
        Write-Host "ERROR: DEVELOPER_$($Developer)_PASSWORD is not set in .env" -ForegroundColor Red
        exit 1
    }

    # Set DATABASE_URL in the current process environment so env.py picks it up.
    # This only affects the current PowerShell session and child processes.
    $previousUrl = $env:DATABASE_URL
    $env:DATABASE_URL = "postgresql://${dbUser}:${dbPass}@localhost:5432/${dbName}"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

switch ($Command) {

    "help" {
        Show-Help
    }

    "upgrade" {
        $t = if ($Target) { $Target } else { "head" }
        Write-Section "Upgrading $dbName to: $t"
        Invoke-Alembic @("upgrade", $t)
    }

    "downgrade" {
        $t = if ($Target) { $Target } else { "-1" }
        Write-Section "Downgrading $dbName to: $t"
        Invoke-Alembic @("downgrade", $t)
    }

    "current" {
        Write-Section "Current revision - $dbName"
        Invoke-Alembic @("current")
    }

    "history" {
        Write-Section "Migration History"
        Invoke-Alembic @("history", "--verbose")
    }

    "revision" {
        if (-not $Message) {
            $Message = Read-Host "Migration description"
        }
        Write-Section "Creating Migration: $Message"
        Invoke-Alembic @("revision", "-m", $Message)
        Write-Host ""
        Write-Host "New migration file created in migrations/versions/." -ForegroundColor Green
        Write-Host "Open it and fill in the upgrade() and downgrade() functions." -ForegroundColor Green
    }
}

# Restore DATABASE_URL to whatever it was before this script ran.
if ($Developer -ne "") {
    $env:DATABASE_URL = $previousUrl
}
