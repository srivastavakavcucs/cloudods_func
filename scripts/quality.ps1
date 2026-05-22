<#
.SYNOPSIS
    Code quality checks for the Python Logging Example project.

.DESCRIPTION
    Runs linting, type checking, security analysis, tests, and complexity checks.
    Supports individual check commands or running all checks at once.

.EXAMPLE
    .\run.ps1 quality -Help
    .\run.ps1 quality -All
    .\run.ps1 quality -Ruff
#>

param(
    [Parameter(Position = 0)]
    [string]$Command = "",

    [switch]$Help,
    [switch]$All,
    [switch]$Ruff,
    [switch]$Pylint,
    [switch]$Mypy,
    [switch]$Bandit,
    [switch]$Tests,
    [switch]$Coverage,
    [switch]$Radon,
    [switch]$Xenon,
    [switch]$Format
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

# Ensure venv tools (ruff, pylint, mypy, bandit, pytest, etc.) are on PATH
# regardless of whether the venv is activated in the calling terminal.
$venvScripts = Join-Path $projectRoot "venv\Scripts"
if (Test-Path $venvScripts) {
    $env:PATH = "$venvScripts;$env:PATH"
}

# Report paths
$reportsDir = Join-Path $projectRoot "reports"
$reportPaths = @{
    "coverage" = Join-Path $reportsDir "coverage"
    "pylint" = Join-Path $reportsDir "pylint.json"
    "bandit" = Join-Path $reportsDir "bandit.json"
    "ruff" = Join-Path $reportsDir "ruff.json"
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
     Python Logging Example - Quality Checks
================================================================================

USAGE:
    .\run.ps1 quality [OPTIONS]

OPTIONS:
    -Help              Show this help message
    -All               Run all quality checks and tests
    -Ruff              Run Ruff linter and formatter
    -Pylint            Run Pylint static analysis
    -Mypy              Run MyPy type checking
    -Bandit            Run Bandit security scanning
    -Tests             Run pytest unit tests
    -Coverage          Run pytest with coverage report
    -Radon             Run Radon complexity analysis
    -Xenon             Run Xenon complexity monitoring
    -Format            Format code with Ruff

EXAMPLES:
    .\run.ps1 quality -Help                      # Show this help
    .\run.ps1 quality -All                       # Run all checks
    .\run.ps1 quality -Tests                     # Run tests without coverage
    .\run.ps1 quality -Tests -Coverage           # Run tests with coverage report
    .\run.ps1 quality -Ruff -Tests               # Run Ruff and tests
    .\run.ps1 quality -Ruff -Tests -Coverage     # Run Ruff and tests with coverage
    .\run.ps1 quality -Format                    # Format code only

NOTE:
    If no options are provided, shows this help message.
    To start the app or Docker stack, use .\run.ps1 docker-stack.
"@
}

# Main execution
if ($Help -or $Command -eq "help" -or ($PSBoundParameters.Count -eq 0)) {
    Show-Help
}
elseif ($All) {
    Write-Section "Running All Checks"

    Write-Section "Ruff - Checking"
    ruff check . --config pyproject.toml --output-format=json > $reportPaths.ruff
    Write-Host "Ruff report saved to: $($reportPaths.ruff)" -ForegroundColor Gray

    Write-Section "Ruff - Formatting"
    ruff format . --config pyproject.toml

    Write-Section "Pylint - Static Analysis"
    pylint src --output-format=json 2>$null | Out-File -FilePath $reportPaths.pylint -Encoding utf8
    Write-Host "Pylint report saved to: $($reportPaths.pylint)" -ForegroundColor Gray

    Write-Section "MyPy - Type Checking"
    mypy src

    Write-Section "Bandit - Security Analysis"
    bandit -r src -f json -o $reportPaths.bandit
    Write-Host "Bandit report saved to: $($reportPaths.bandit)" -ForegroundColor Gray

    Write-Section "PyTest - Unit Tests"
    pytest -v

    Write-Section "PyTest - Coverage Report"
    pytest --cov=src --cov-report=term --cov-report=html:$($reportPaths.coverage)
    Write-Host "Coverage report saved to: $($reportPaths.coverage)/index.html" -ForegroundColor Gray

    Write-Section "Radon - Complexity Analysis"
    radon cc src -a
    Write-Host ""
    radon mi src

    Write-Section "Xenon - Complexity Monitoring"
    xenon src --max-absolute 10 --max-modules 10 --max-average 10

    Write-Host ""
    Write-Host "All checks completed!"
}
else {
    if ($Ruff) {
        Write-Section "Ruff - Linter and Formatter"
        ruff check . --fix --output-format=json 2>$null | Out-File -FilePath $reportPaths.ruff -Encoding utf8
        ruff format .

        # Parse JSON output and print summary
        $ruffJson = Get-Content $reportPaths.ruff -Raw -ErrorAction SilentlyContinue
        if ($ruffJson) {
            $violations = $ruffJson | ConvertFrom-Json
            $byFile = $violations | Group-Object -Property filename
            $failedCount = $byFile.Count
            $allPyFiles = (Get-ChildItem -Recurse -Filter "*.py" -Path $projectRoot | Where-Object { $_.FullName -notmatch "\\\.venv\\" -and $_.FullName -notmatch "__pycache__" }).Count
            $passedCount = $allPyFiles - $failedCount

            Write-Host ""
            Write-Host "Ruff Summary" -ForegroundColor Cyan
            Write-Host ("=" * 40) -ForegroundColor Cyan
            Write-Host ("  Files checked : {0}" -f $allPyFiles)
            Write-Host ("  Passed        : {0}" -f $passedCount) -ForegroundColor Green
            Write-Host ("  Failed        : {0}" -f $failedCount) -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "Green" })
            Write-Host ("  Total issues  : {0}" -f $violations.Count) -ForegroundColor $(if ($violations.Count -gt 0) { "Red" } else { "Green" })

            if ($failedCount -gt 0) {
                Write-Host ""
                foreach ($group in $byFile | Sort-Object Name) {
                    $relPath = $group.Name.Replace($projectRoot, "").TrimStart("\", "/")
                    Write-Host ("  {0}" -f $relPath) -ForegroundColor Yellow
                    foreach ($v in $group.Group | Sort-Object { $_.location.row }) {
                        Write-Host ("    Line {0,-5} [{1}] {2}" -f $v.location.row, $v.code, $v.message)
                    }
                }
            }
        } else {
            Write-Host ""
            Write-Host "  No violations found." -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "Ruff report saved to: $($reportPaths.ruff)" -ForegroundColor Gray
    }

    if ($Pylint) {
        Write-Section "Pylint - Static Analysis"
        pylint src --output-format=json 2>$null | Out-File -FilePath $reportPaths.pylint -Encoding utf8

        $pylintJson = Get-Content $reportPaths.pylint -Raw -ErrorAction SilentlyContinue
        if ($pylintJson) {
            $messages = @($pylintJson | ConvertFrom-Json)

            $allPySrcFiles  = (Get-ChildItem -Recurse -Filter "*.py" -Path (Join-Path $projectRoot "src") | Where-Object { $_.FullName -notmatch "__pycache__" }).Count
            $filesWithIssues = ($messages | Select-Object -ExpandProperty path -Unique).Count
            $filesPassed    = $allPySrcFiles - $filesWithIssues

            $errorCount      = ($messages | Where-Object { $_.type -in @("error", "fatal") }).Count
            $warningCount    = ($messages | Where-Object { $_.type -eq "warning" }).Count
            $conventionCount = ($messages | Where-Object { $_.type -eq "convention" }).Count
            $refactorCount   = ($messages | Where-Object { $_.type -eq "refactor" }).Count

            Write-Host ""
            Write-Host "Pylint Summary" -ForegroundColor Cyan
            Write-Host ("=" * 40) -ForegroundColor Cyan
            Write-Host ("  Files scanned : {0}" -f $allPySrcFiles)
            Write-Host ("  Passed        : {0}" -f $filesPassed)  -ForegroundColor Green
            Write-Host ("  Failed        : {0}" -f $filesWithIssues) -ForegroundColor $(if ($filesWithIssues -gt 0) { "Red" } else { "Green" })
            Write-Host ("  Total issues  : {0}" -f $messages.Count) -ForegroundColor $(if ($messages.Count -gt 0) { "Red" } else { "Green" })
            Write-Host ""
            Write-Host ("  Issues by type:")
            Write-Host ("    Errors/Fatal : {0}" -f $errorCount)      -ForegroundColor $(if ($errorCount -gt 0)      { "Red" }    else { "Green" })
            Write-Host ("    Warnings     : {0}" -f $warningCount)    -ForegroundColor $(if ($warningCount -gt 0)    { "Yellow" } else { "Green" })
            Write-Host ("    Conventions  : {0}" -f $conventionCount) -ForegroundColor $(if ($conventionCount -gt 0) { "Yellow" } else { "Green" })
            Write-Host ("    Refactors    : {0}" -f $refactorCount)   -ForegroundColor $(if ($refactorCount -gt 0)   { "Yellow" } else { "Green" })

            if ($messages.Count -gt 0) {
                Write-Host ""
                $byFile = $messages | Group-Object -Property path | Sort-Object Name
                foreach ($group in $byFile) {
                    $relPath = $group.Name.Replace($projectRoot, "").TrimStart("\", "/")
                    Write-Host ("  {0}" -f $relPath) -ForegroundColor Yellow
                    foreach ($msg in $group.Group | Sort-Object line) {
                        $msgColor = switch ($msg.type) {
                            "error"      { "Red" }
                            "fatal"      { "Red" }
                            "warning"    { "Yellow" }
                            default      { "White" }
                        }
                        Write-Host ("    Line {0,-5} [{1}] {2}" -f $msg.line, $msg."message-id", $msg.message) -ForegroundColor $msgColor
                    }
                }
            }
        } else {
            Write-Host ""
            Write-Host "  No issues found." -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "Pylint report saved to: $($reportPaths.pylint)" -ForegroundColor Gray
    }

    if ($Mypy) {
        Write-Section "MyPy - Type Checking"
        mypy src
    }

    if ($Bandit) {
        Write-Section "Bandit - Security Scanning"
        bandit -r src -f json -o $reportPaths.bandit 2>$null

        $banditJson = Get-Content $reportPaths.bandit -Raw -ErrorAction SilentlyContinue
        if ($banditJson) {
            $banditReport = $banditJson | ConvertFrom-Json

            $fileMetrics   = $banditReport.metrics.PSObject.Properties | Where-Object { $_.Name -ne "_totals" }
            $filesScanned  = $fileMetrics.Count
            $issues        = @($banditReport.results)
            $errors        = @($banditReport.errors)
            $filesWithIssues = ($issues | Select-Object -ExpandProperty filename -Unique).Count
            $filesPassed   = $filesScanned - $filesWithIssues

            $highCount   = ($issues | Where-Object { $_.issue_severity -eq "HIGH" }).Count
            $mediumCount = ($issues | Where-Object { $_.issue_severity -eq "MEDIUM" }).Count
            $lowCount    = ($issues | Where-Object { $_.issue_severity -eq "LOW" }).Count

            Write-Host ""
            Write-Host "Bandit Summary" -ForegroundColor Cyan
            Write-Host ("=" * 40) -ForegroundColor Cyan
            Write-Host ("  Files scanned : {0}" -f $filesScanned)
            Write-Host ("  Passed        : {0}" -f $filesPassed) -ForegroundColor Green
            Write-Host ("  Failed        : {0}" -f $filesWithIssues) -ForegroundColor $(if ($filesWithIssues -gt 0) { "Red" } else { "Green" })
            Write-Host ("  Errors        : {0}" -f $errors.Count) -ForegroundColor $(if ($errors.Count -gt 0) { "Red" } else { "Green" })
            Write-Host ""
            Write-Host ("  Issues by severity:")
            Write-Host ("    High   : {0}" -f $highCount)   -ForegroundColor $(if ($highCount -gt 0)   { "Red" }    else { "Green" })
            Write-Host ("    Medium : {0}" -f $mediumCount) -ForegroundColor $(if ($mediumCount -gt 0) { "Yellow" } else { "Green" })
            Write-Host ("    Low    : {0}" -f $lowCount)    -ForegroundColor $(if ($lowCount -gt 0)    { "Yellow" } else { "Green" })

            if ($issues.Count -gt 0) {
                Write-Host ""
                $byFile = $issues | Group-Object -Property filename | Sort-Object Name
                foreach ($group in $byFile) {
                    $relPath = $group.Name.Replace($projectRoot, "").TrimStart("\", "/")
                    Write-Host ("  {0}" -f $relPath) -ForegroundColor Yellow
                    foreach ($issue in $group.Group | Sort-Object line_number) {
                        $severityColor = switch ($issue.issue_severity) {
                            "HIGH"   { "Red" }
                            "MEDIUM" { "Yellow" }
                            default  { "White" }
                        }
                        Write-Host ("    Line {0,-5} [{1}] {2} (Confidence: {3})" -f `
                            $issue.line_number, $issue.test_id, $issue.issue_text, $issue.issue_confidence) `
                            -ForegroundColor $severityColor
                    }
                }
            }

            if ($errors.Count -gt 0) {
                Write-Host ""
                Write-Host "  Scan errors:" -ForegroundColor Red
                foreach ($err in $errors) {
                    Write-Host ("    {0}: {1}" -f $err.filename, $err.reason) -ForegroundColor Red
                }
            }
        }

        Write-Host ""
        Write-Host "Bandit report saved to: $($reportPaths.bandit)" -ForegroundColor Gray
    }

    if ($Tests -and $Coverage) {
        Write-Section "PyTest - Unit Tests with Coverage"
        pytest --cov=src -v --cov-report=term --cov-report=html:$($reportPaths.coverage)
        Write-Host "Coverage report saved to: $($reportPaths.coverage)/index.html" -ForegroundColor Gray
    }
    elseif ($Tests) {
        Write-Section "PyTest - Unit Tests"
        pytest -v
    }
    elseif ($Coverage) {
        Write-Section "PyTest - Coverage Report"
        pytest --cov=src -v --cov-report=term --cov-report=html:$($reportPaths.coverage)
        Write-Host "Coverage report saved to: $($reportPaths.coverage)/index.html" -ForegroundColor Gray
    }

    if ($Radon) {
        Write-Section "Radon - Complexity Analysis"
        radon cc src -a
        Write-Host ""
        radon mi src
    }

    if ($Xenon) {
        Write-Section "Xenon - Complexity Monitoring"
        xenon src --max-absolute 10 --max-modules 10 --max-average 10
    }

    if ($Format) {
        Write-Section "Ruff - Format Code"
        ruff format .
    }
}
