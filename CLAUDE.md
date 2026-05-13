# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

`zsh-aws` is a Zsh plugin forked from Oh-My-Zsh's [`aws`](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/aws) plugin. It provides:

- AWS CLI tab-completion (via AWS CLI v2's `aws_completer`, or a bundled `bash_completion` fallback).
- Profile-management helpers (`alp`, `agp`, `agr`, `asp`, `asr`, `acp`, `acak`, `achain`, `awhoami`).
- An `aws_prompt_info` function consumed by Zsh themes, with optional region and credential-TTL segments.

## Layout

- `zsh-aws.plugin.zsh` — the plugin. Sourced by plugin managers (e.g. `zplug "apachler/zsh-aws"`).
- `bin/aws_zsh_completer.sh` — fallback bash-compat completer used when AWS CLI v2's `aws_completer` is not on `PATH`. The plugin prepends `${0:h}/bin` to `PATH` (unless `$PMSPEC` contains `b`, meaning the plugin manager already handles PATH).
- `test/run-tests.zsh` — assertion-based smoke tests. Sets up a temp `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` and exercises the public surface without touching the real AWS CLI.
- `.github/workflows/ci.yml` — runs `zsh -n` and the test suite on `ubuntu-latest` + `macos-latest`. The matrix matters because `_aws_iso_to_epoch` has separate GNU vs BSD `date` codepaths.
- `README.md` — user-facing docs. Keep it in sync when adding or renaming commands/options.

## Architecture notes that aren't obvious from a single file

- **`_aws_load_profile <profile>` is the source of truth for profile data.** It populates the global associative array `_aws_profile_data` by reading both `$AWS_CONFIG_FILE` and `$AWS_SHARED_CREDENTIALS_FILE` in one pass. Anything that needs `role_arn`, `mfa_serial`, `source_profile`, `sso_session`, `credential_source`, `mfa_command`, etc. reads from there — do not reintroduce `aws configure get` calls. Each `aws configure get` is ~150–400 ms cold and `acp` would call it ~9 times.
- **Profile discovery (`alp`) drives completion.** `alp` reads the same two files and unions the section names. Its result is memoized in `_aws_alp_cache` keyed on `path:mtime:path:mtime` via `zmodload zsh/stat`. Adding a profile-taking command means: append it to the `compdef _zsh_aws_profile_complete …` line and, if needed, update the `_zsh_aws_profile_complete` description format. Region-taking commands use a separate `compdef _zsh_aws_region_complete …` line backed by the static `_AWS_REGIONS` array — add new regions there (no API call: that would need credentials and would block tab-completion).
- **`asp` vs `acp` is a deliberate split.**
  - `asp` only exports `AWS_PROFILE` / `AWS_DEFAULT_PROFILE` / `AWS_EB_PROFILE` and lets the AWS SDK resolve credentials lazily.
  - `acp` additionally:
    - **SSO**: if `sso_session` or `sso_start_url` is set, runs `aws sso login` and `aws configure export-credentials`. Short-circuits before the MFA / sts path. Falls back to "set only `AWS_PROFILE`" when `export-credentials` is missing (CLI < 2.13).
    - **MFA**: prompts with `read -rs` (no echo) or runs `mfa_command` non-interactively. Validates 6-digit format and `duration_seconds` in `900..43200` before calling `sts`.
    - **assume-role**: respects `role_arn`, `source_profile`, `external_id`, `role_session_name`, and `credential_source` (mutually exclusive with `source_profile`). When `source_profile` is unset, falls back to the role profile itself — *not* the literal string `"profile"`.
    - **Expiration**: captures `Credentials.Expiration` from sts and exports `AWS_CREDENTIAL_EXPIRATION` (ISO 8601) plus `_AWS_CREDENTIAL_EXPIRATION_EPOCH` (Unix seconds, sidecar for cheap prompt math).
  - Both clear the same env vars when called with no argument (and `acp` also clears `AWS_CREDENTIAL_EXPIRATION` + `_AWS_CREDENTIAL_EXPIRATION_EPOCH`). Preserve this contract.
- **Prompt injection is opt-out.** At source time the plugin prepends `$(aws_prompt_info)` to `RPROMPT` unless `SHOW_AWS_PROMPT=false` or `RPROMPT` already contains it. Don't change to an unconditional assignment — themes that set `RPROMPT` themselves rely on this guard. `aws_prompt_info` itself short-circuits when `AWS_PROFILE` is empty; it composes profile + optional `@<region>` + optional ` <TTL>` (or red `EXPIRED`) segments.
- **TTL math avoids forking.** `aws_prompt_info` reads `$EPOCHSECONDS` (provided by `zmodload zsh/datetime`, loaded at plugin source). Don't reintroduce `$(date +%s)` here — it runs on every prompt redraw.
- **ISO-8601 → epoch is platform-split.** `_aws_iso_to_epoch` tries GNU `date -d` first, then BSD/macOS `date -j -f`. The CI macOS job exists specifically to keep the BSD path honest.
- **Completer selection is order-sensitive and cached cross-shell.** AWS CLI v2's `aws_completer` is preferred. The fallback search for `aws_zsh_completer.sh` (Homebrew, Ubuntu, NixOS, RPM) only runs once per machine: the resolved path is persisted under `${XDG_CACHE_HOME:-$HOME/.cache}/zsh-aws/completer-path` to skip the ~400 ms `brew --prefix awscli` cost on every shell. New install locations should be appended to the `elif` chain, not replace existing entries.
- **Modern completion uses `compdef`.** `_zsh_aws_profile_complete` uses `_describe` to surface each profile's region and role basename in the menu. A `compctl` fallback remains for environments where `compinit` hasn't run.
- **Plugin header follows the [Zsh Plugin Standard](https://github.com/zdharma/Zsh-100-Commits-Club/blob/master/Zsh-Plugin-Standard.adoc).** The two-line `0=…` dance at the top resolves the plugin's own path under various loaders — don't simplify it.

## Working on the plugin

### Running tests

```zsh
zsh test/run-tests.zsh
```

This is the fast inner loop. The suite uses a tempdir-backed config and credentials file, so it never touches the real AWS CLI or `~/.aws/`.

### Manual smoke

```zsh
# In a fresh zsh, with ~/.aws/config populated:
autoload -Uz compinit && compinit
autoload -Uz bashcompinit && bashcompinit
source ./zsh-aws.plugin.zsh

alp                # list profiles
alp -v             # with region / role columns
asp <profile>      # tab-completion should offer profiles with descriptions
agp                # echo current $AWS_PROFILE
asr eu-west-1      # set region
acp <profile>      # exercise MFA / assume-role / SSO paths
achain <profile>   # walk source_profile chain
awhoami            # caller identity
```

When changing shell code, keep it `zsh`-only (uses `(ps:\t:)`, `${(j:, :)…}`, `compctl`, `${0:h}`, `[[ … ]] { … }`) — do not "portability-fix" it to bash.

## Conventions

- User-facing error messages go to stderr and use `${fg[red]}…${reset_color}` (see `asp` / `acp` / `acak`). Match that style for new errors.
- Functions accept a single positional profile/region argument; calling with no argument clears the relevant state and prints a confirmation. Preserve this for any new helper.
- `$AWS_CONFIG_FILE` and `$AWS_SHARED_CREDENTIALS_FILE` must be honored with defaults expressed as `${AWS_CONFIG_FILE:-$HOME/.aws/config}` / `${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}` — don't hardcode the paths.
- Prefer parsing config via `_aws_load_profile` over forking `aws configure get`. The cost difference is ~10× per call.
- Avoid `(( i++ ))` under `set -e` (test harness uses it via the assertion counters). Prefer `(( ++i ))` for safety.
