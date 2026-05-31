# macOS Smoke Known Issues

Last updated: 2026-06-01
Branch: `actions/macos-installer-smoke-crs2`

## Scope

This branch exists to validate the macOS installer against the `CRS2.0` config format.
The older reference branch `actions/macos-installer-smoke` was created around the old smoke shape and skipped CRS config generation with `--skip-crs-config`, so it is not a full CRS2.0 reference.

## Reference Run

- Failed run on 2026-05-31:
  `https://github.com/bluescola/codex_download_script/actions/runs/26716282224`

## Known Issues Seen During Bring-up

### 1. `Dry run` can fail on GitHub macOS runners before the real install path starts

- Observed on 2026-05-31 in run `26716282224`.
- The failure happened before the mocked CRS2.0 install step ran, so it did not prove or disprove the real CRS2.0 path.
- Current workaround in the workflow:
  keep `Dry run` as `continue-on-error: true` so the main CRS2.0 smoke path can still execute.
- Follow-up:
  capture the exact runner log from a later authenticated session and fix the installer-side root cause if it is reproducible.

### 2. `CRS2.0` remote branch content is not the same as the older smoke branch

- `origin/actions/macos-installer-smoke` already contains `.github/` and `script-modules/`.
- `origin/CRS2.0` did not have tracked `.github/` or `script-modules/` when this smoke branch was created.
- Impact:
  this smoke branch currently carries the workflow context that the base `CRS2.0` branch does not yet carry.

### 3. PowerShell commit message encoding produced mojibake in Git history

- The first push on this branch created a commit with garbled Chinese text in `git log`.
- Symptom:
  Git warned that the commit message did not conform to UTF-8.
- Safer options next time:
  use an ASCII commit message, or write the message file with explicit UTF-8 that Git will read correctly before `git commit`.

### 4. Local GitHub tooling was limited during triage

- `gh` CLI was not installed in the local environment.
- Unauthenticated GitHub REST requests hit rate limits quickly.
- Impact:
  deep log retrieval from the Actions API was slower than expected.

### 5. `backup_if_exists()` exited the CRS2.0 config-only step when target files did not exist yet

- Observed on 2026-06-01 while analyzing run `26718450860`.
- Root cause:
  `configure_crs()` captures `backup_if_exists "$config_path"` and `backup_if_exists "$auth_path"` inside command substitution while the script runs with `set -e`.
  When the target file did not exist yet, `backup_if_exists()` fell through the `if [[ -f ... ]]` branch and returned non-zero, which terminated the whole step before the config write.
- Fix:
  make `backup_if_exists()` return success when there is nothing to back up.

### 6. macOS Actions annotations may point at workflow line numbers without exposing script stderr

- Observed on 2026-06-01 in run `26718707274`.
- Symptom:
  GitHub only reported `Process completed with exit code 1.` against the workflow YAML line, without the failing shell command from the installer path.
- Current mitigation in the smoke branch:
  the workflow now splits `CRS2.0 config` and `NO_PROXY` into separate steps and prints the captured step log back into the Actions UI on failure.

### 7. `CRS2.0` config step can silently fall back to interactive prompts if env propagation is unclear

- Observed on 2026-06-01 in run `26718891077`.
- Symptom:
  the captured log reached `Starting CRS configuration...` and stopped before logging `Using CRS base_url...` or `Using CRS 2.0 token...`.
- Current mitigation in the smoke branch:
  the installer now emits explicit non-interactive errors when `CODEX_CRS_BASE_URL` or `CODEX_CRS_OPENAI_API_KEY` is missing, and the workflow echoes whether both env vars are set before invoking the config step.

### 8. Current remaining failure is inside `configure_crs()` after env detection, not in GitHub macOS runner setup

- Observed on 2026-06-01 in run `26718973268`.
- Confirmed facts:
  `Dry run`, `node@24` preparation, and `Install with mocked CRS 2.0 endpoint` all passed on both `macos-14` and `macos-15`.
  The config step also confirmed `CODEX_CRS_BASE_URL=set` and `CODEX_CRS_OPENAI_API_KEY=set`.
- Implication:
  the remaining failure is now in the installer script's CRS2.0 config path itself, so workflow/platform tuning is no longer the primary bottleneck.

### 9. `configure_crs()` now reaches URL auto-correction successfully before the remaining exit

- Observed on 2026-06-01 in run `26719216861`.
- Confirmed facts:
  the script now logs the full `/api` -> `/openai` auto-correction path and confirms `CRS Responses route probe: 200`.
- Implication:
  the unresolved failure is after `resolve_crs_base_url()` and after env capture, so the next debugging surface is the escape/write phase or the `CODEX_HOME` directory preparation.

### 10. Current remaining failure is narrow enough that generic step annotations are no longer sufficient

- Observed on 2026-06-01 in run `26719317167`.
- Symptom:
  the latest visible installer line is `CRS config values escaped.`, but GitHub annotations still do not expose the exact failing shell command after that point.
- Current mitigation in the smoke branch:
  the config-only step now runs the installer under `bash -x` and emits a larger tail window on failure so the next run should show the exact command or branch that exits.

### 11. Legacy `CRS_OAI_KEY` cleanup can still terminate the config-only step after successful file writes

- Observed on 2026-06-01 in run `26719582470`.
- Confirmed facts:
  the trace now reaches `CRS config files written to disk.`
  the remaining failure happens during the follow-up `unset CRS_OAI_KEY` cleanup stage.
- Fix:
  skip the `unset` when `CRS_OAI_KEY` is a readonly shell variable, instead of relying on `unset ... || true`.

## Current Workflow Intent

The workflow should validate these CRS2.0-specific behaviors on `macos-14` and `macos-15`:

- shell syntax for the mac installer and NO_PROXY script
- real installer execution without `--skip-crs-config`
- `/api` to `/openai` CRS base URL correction
- `config.toml` values for OpenAI-compatible Responses mode
- `auth.json` token write
- `NO_PROXY` and `no_proxy` updates for the CRS host and port
