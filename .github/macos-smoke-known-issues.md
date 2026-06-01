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

### 12. Legacy profile cleanup should be best-effort, not a hard failure

- Observed on 2026-06-01 while iterating on runs `26719582470` and `26719698277`.
- Rationale:
  removing stale `CRS_OAI_KEY` exports from shell profile files is helpful hygiene, but it should not block a successful CRS2.0 install after `config.toml` and `auth.json` are already written.
- Current mitigation in the smoke branch:
  legacy shell-variable/profile cleanup now logs warnings and continues instead of aborting the installer.

### 13. GitHub annotations were showing the oldest lines from the tail window, not the true final failing lines

- Observed on 2026-06-01 while comparing runs `26719698277` and `26719769769`.
- Symptom:
  the annotations kept stopping around the `.zprofile` / `.bash_profile` cleanup trace, but that was still not enough to prove the actual final failing command.
- Current mitigation in the smoke branch:
  on config-step failure, the workflow now emits the last 12 installer log lines in reverse order so GitHub annotations show the newest lines first.

### 14. `GITHUB_ENV` propagation was not sufficient as the only carrier for the discovered CRS artifact path

- Observed on 2026-06-01 in run `26730645012`.
- Symptom:
  `Apply CRS 2.0 config only` succeeded, but `Verify commands and CRS 2.0 artifacts` still saw `CODEX_SMOKE_HOME` as empty on both `macos-14` and `macos-15`.
- Current mitigation in the smoke branch:
  the config step now also writes the resolved `.codex` path into a workspace marker file, and the verify step can recover or rediscover the path before running assertions.

### 15. `set -euo pipefail` in verify can still hide the failing assertion when a raw probe command exits first

- Observed on 2026-06-01 in run `26730817976`.
- Symptom:
  after the artifact-path recovery change, both jobs still failed in `Verify commands and CRS 2.0 artifacts`, but the annotations no longer identified which check failed.
- Current mitigation in the smoke branch:
  verify now resolves command paths, versions, auth token, and PATH counts into explicit variables first, then validates them with labeled assertions so the next run exposes the concrete failing check.

### 16. Sourcing shell profile files under `set -u` is fragile on GitHub macOS runners

- Observed on 2026-06-01 while iterating after run `26730939122`.
- Rationale:
  the verify step sources `~/.zprofile`, `~/.zshrc`, `~/.bash_profile`, and `~/.bashrc` to emulate a fresh terminal, but runner or user profile code can reference unset variables that immediately terminate the shell under `nounset`.
- Current mitigation in the smoke branch:
  verify now temporarily disables `nounset` while loading profile files, then restores it before running the actual smoke assertions.

### 17. Full runner shell profiles are too noisy a surface for deterministic smoke verification

- Observed on 2026-06-01 after runs `26730939122` and `26731058840` still failed inside verify without stable, actionable annotations.
- Rationale:
  even after hardening `nounset`, sourcing the entire runner profile set still mixes GitHub-hosted defaults with our installer-managed exports, which makes the smoke result harder to attribute to the installer itself.
- Current mitigation in the smoke branch:
  verify now extracts only the installer-managed PATH and NO_PROXY blocks from the shell profile files and evaluates them inside a clean `bash --noprofile --norc` environment.

### 18. Nested heredoc terminators inside a workflow `run: |` block are indentation-sensitive

- Observed on 2026-06-01 in run `26731310354`.
- Symptom:
  GitHub rejected the workflow before creating any jobs, with an `Invalid workflow file` error pointing at the inner `BASH` terminator line.
- Fix:
  keep the nested heredoc terminator aligned with the surrounding script indentation expected by the workflow block so the YAML/run-script boundary remains valid.

### 19. Combining `if ! ... <<'HEREDOC'` with a long embedded shell body is brittle to debug and easy to misclose

- Observed on 2026-06-01 while extracting the verify step locally for syntax checking.
- Symptom:
  the verify block could reach `unexpected end of file` at shell-parse time even when the surrounding workflow YAML was accepted.
- Current mitigation in the smoke branch:
  the managed-shell verification body is now written to a temporary script file and executed explicitly, instead of being embedded directly as a command heredoc inside the `if ! ...` statement.

### 20. Plain `tail | sed 's/^/::error::/'` was still not reliably surfacing verify failures as annotations

- Observed on 2026-06-01 after run `26731825518`.
- Symptom:
  the verify step still failed, but GitHub annotations continued to collapse to a generic `Process completed with exit code 1.` line.
- Current mitigation in the smoke branch:
  verify failure now replays the last lines of `verify-managed-shell.log` through a small Python emitter so each line is written back as an explicit `::error::...` annotation.

### 21. When GitHub still collapses a large verify step, split the assertions into separate steps

- Observed on 2026-06-01 after run `26731887981` still reduced the failure to a generic exit annotation.
- Rationale:
  once artifact creation, config writing, and NO_PROXY application all pass, a single large `Verify ...` step is the remaining low-observability surface.
- Current mitigation in the smoke branch:
  the verification path is now split into separate steps for CRS artifacts, managed node/codex shell state, and managed NO_PROXY shell state so the failing surface is naturally exposed even when log annotations are poor.

### 22. Python heredocs inside workflow shell blocks must not keep shell indentation

- Observed on 2026-06-01 while reproducing the `Verify CRS 2.0 artifacts` failure from run `26732318764`.
- Symptom:
  an inline `python3 - <<'PY'` block inside the workflow carried leading shell indentation into Python stdin, which produced `IndentationError: unexpected indent` before any smoke assertion ran.
- Fix:
  keep the Python body left-aligned inside the heredoc content, even when the surrounding workflow `run: |` block is indented.

### 23. For short workflow helpers, `python3 -c` is safer than nested heredocs

- Observed on 2026-06-01 while iterating on the split verify steps after run `26732400557`.
- Rationale:
  once a workflow `run: |` block already contains shell functions and nested script generation, additional inline Python heredocs add another parsing boundary that is easy to destabilize.
- Current mitigation in the smoke branch:
  short Python helpers in the verify path now use `python3 -c` instead of nested heredocs.

### 24. The first verify step also needs its own explicit log capture wrapper

- Observed on 2026-06-01 after run `26732483222` still failed in `Verify CRS 2.0 artifacts` without exposing the concrete assertion.
- Rationale:
  splitting the verify path by step isolated the failing layer, but the first artifact-check step still needed the same explicit log replay treatment as the later managed-shell checks.
- Current mitigation in the smoke branch:
  `Verify CRS 2.0 artifacts` now runs inside a captured bash sub-script and replays the captured log lines back into the Actions UI on failure.

## Current Workflow Intent

The workflow should validate these CRS2.0-specific behaviors on `macos-14` and `macos-15`:

- shell syntax for the mac installer and NO_PROXY script
- real installer execution without `--skip-crs-config`
- `/api` to `/openai` CRS base URL correction
- `config.toml` values for OpenAI-compatible Responses mode
- `auth.json` token write
- `NO_PROXY` and `no_proxy` updates for the CRS host and port
### 25. Failure-log replay helpers inside workflow steps should avoid nested Python heredocs

- Observed on 2026-06-01 after run `26732658586` returned `Process completed with exit code 2.` in `Verify CRS 2.0 artifacts`.
- Symptom:
  the step body itself was valid, but the failure branch used an indented `python3 - "$verify_log" <<'PY'` block. Bash does not accept an indented heredoc terminator, so the log-replay path masked the real smoke failure with a shell parse error.
- Current mitigation in the smoke branch:
  failure-log replay now uses plain shell (`tail | sed 's/^/::error::/'`) instead of nested Python heredocs inside workflow `run: |` blocks.

### 26. Logging helpers used under `set -e` should return success explicitly on older macOS bash

- Observed on 2026-06-01 after run `26732963456` failed in `Apply CRS 2.0 config only` immediately after writing `auth.json`.
- Symptom:
  the visible tail log stopped at `log_ok "Auth file updated for CRS 2.0 / OpenAI-compatible mode"`, and the final traced command was `[[ 0 -ne 1 ]]` from `codex_log_emit()`. On the GitHub macOS runner bash, the logging helper needed an explicit success return so a false condition inside its optional file-log branch did not surface as the function status under `set -e`.
- Current mitigation in the smoke branch:
  `codex_log_emit()` now uses split `[[ ... ]] && [[ ... ]]` conditions and ends with `return 0`, so normal console logging cannot abort the installer.
