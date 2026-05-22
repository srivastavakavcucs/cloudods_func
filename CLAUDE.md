# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

`CloudODS_Func` stores **Python code for Azure Functions** and the CI/CD pipeline configuration to build and deploy them. It implements pipeline step 3 of the CloudODS Release 1 thin-slice MVP (Blob → Function → Postgres).

---

## Project Layout

```
function_app.py                                   # Azure Functions v2 entrypoint — triggers defined here
host.json                                         # Azure Functions runtime config (v2, extension bundle 4.x)
appsettings.json                                  # Placeholder required by the ARM deploy transform step
pyproject.toml                                    # Build config; runtime deps (azure-functions) + dev deps (ruff, pytest)
src/
└── cloudods_func/
    ├── __init__.py
    └── main.py                                   # Business logic — imported by function_app.py
tests/
└── test_main.py
cicd-pipelines/
├── bodm-pipelines.yml                            # Pipeline entry point — extends Pipeline 2.0
└── pipeline_app_variables/global_variables.yml  # All app variables
```

### Azure Functions structure

`function_app.py` must live at the repo root — the Azure Functions runtime scans for it there. Business logic belongs in `src/cloudods_func/` and is imported by `function_app.py`. The build pipeline installs the `src/` package to `.python_packages/lib/site-packages`, which gets bundled into the deployment zip and picked up by the Functions runtime on Linux.

Current state: HTTP trigger stub at `/api/hello` that prints "Hello CloudODS". Replace with a `@app.blob_trigger(...)` when real processing logic is ready.

---

## Pipeline — Current State

The pipeline uses **Pipeline 2.0** via the `extends:` form, inheriting the shared Python build job from `pipeline-templates`.

### Files

```
cicd-pipelines/
├── bodm-pipelines.yml                            # extends: pipeline-templates (Pipeline 2.0 entry point)
└── pipeline_app_variables/global_variables.yml  # All app variables
```

There is no local `templates/` folder — the build job and Sonar template live in `pipeline-templates`.

### Behavior

| | |
|---|---|
| **Trigger** | Auto-runs on push to `feature/*`, `develop`, `main`. Excludes `cicd-pipelines/**`. |
| **Agent** | `DevOps-AzurePipelines-Ubuntu2204` (default). |
| **Build** | `UsePythonVersion@0` (3.13) → `pip install . --target=.python_packages/lib/site-packages` → `pip install ".[dev]"` → `pytest` (JUnit XML) → archive → publish artifact `CloudODS_Func-artifacts` |
| **Sonar/Snyk** | Runs on PRs targeting `nonprod` or `release/*` |
| **Deploy** | Stages present in the shared template but **not yet functional** — variable groups and service connections not yet provisioned |

### `pipeline-templates` reference

Currently pinned to branch `refs/heads/feature/653316-python-pipeline`. Once that branch merges to `main` in `pipeline-templates` and a tag is cut, update `bodm-pipelines.yml`:

```yaml
# change this line in cicd-pipelines/bodm-pipelines.yml:
ref: "refs/heads/feature/653316-python-pipeline"
# to:
ref: "refs/tags/<new-tag>"
```

### What's working

Build, test, archive, publish artifact — green. Pytest results appear in the ADO Tests tab. Sonar/Snyk PR gates active.

### What's missing (deploy — MVP-blocking gap)

The deploy stage in the shared template requires these ADO admin resources before it can fire:

- Per-env variable groups `<env>-CloudODS_Func-deploy-variables` (appdev, dev, test, stage, uat, prod) containing: `APPTYPE` (`functionAppLinux`), `WEBAPPNAME`, `STARTUPCMD`, `APP_NAME`, `PUBLISH_ARTIFACT`
- ARM service connections per env: `sc-<env>01-vy-wif-CloudODS`

---

## Variable conventions

| Variable | Where defined | Notes |
|---|---|---|
| `app_name` | `global_variables.yml` | Archive `$(app_name).zip`, artifact `$(app_name)-artifacts` |
| `python_version` | `global_variables.yml` | Currently `3.13` |
| `project_type` | `global_variables.yml` | `python` — passed to Pipeline 2.0 to select the correct build job |
| `pipeline-2-0-vars` (ADO group) | ADO project-level | Sonar/Snyk service connections |
| `<env>-CloudODS_Func-deploy-variables` (ADO group) | ADO project-level | Per-env deploy values; not yet provisioned |

ARM service connection convention: `sc-<env>01-vy-wif-<arm_wif_sc_project_name>` → e.g. `sc-appdev01-vy-wif-CloudODS`.

---

## Reference: shared `pipeline-templates`

Cloned locally at `C:\Users\vwldolanc\repos\IaC\pipeline-templates\` (ADO: `CICD_Pipelines/pipeline-templates`).

Key files:
- `templates/standard-flow/extends/extends-initialize-pipeline.yml` — Pipeline 2.0 entry point
- `templates/standard-flow/jobs/jobs-build-pipeline-python.yml` — Python build job (added in `feature/653316-python-pipeline`)
- `templates/standard-flow/jobs/jobs-deploy-pipeline.yml` — deploy orchestration
- `templates/standard-flow/steps/steps-deploy-common-arm.yml` — ARM deploy (downloads artifact, transforms appsettings.json, runs `AzureRmWebAppDeployment@4`)
- `templates/validate/steps/steps-security-scanning-sonar.yml` — Sonar; Python case uses `scannerMode: cli`
