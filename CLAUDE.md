# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

`zsh-aws` is a Zsh plugin forked from Oh-My-Zsh's [`aws`](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/aws) plugin. It provides:

- AWS CLI tab-completion (via AWS CLI v2's `aws_completer`, or a bundled `bash_completion` fallback).
- Profile-management helpers (`alp`, `agp`, `asp`, `acp`, `acak`).
- An `aws_prompt_info` function consumed by Zsh themes.

There is no build system, package manifest, lint config, or test suite — the repo is two shell files plus a README. Treat changes as you would a plain `.zshrc` snippet: edit, source it in a real shell, and exercise the functions interactively.

## Layout

- `zsh-aws.plugin.zsh` — the plugin. Sourced by plugin managers (e.g. `zplug "apachler/zsh-aws"`).
- `bin/aws_zsh_completer.sh` — fallback bash-compat completer used when AWS CLI v2's `aws_completer` is not on `PATH`. The plugin prepends `${0:h}/bin` to `PATH` (unless `$PMSPEC` contains `b`, meaning the plugin manager already handles PATH).
- `README.md` — user-facing docs. Keep it in sync when adding or renaming commands/options.

## Architecture notes that aren't obvious from a single file

- **Profile discovery (`alp`) drives completion.** `compctl -K _aws_profiles asp acp acak` calls `_aws_profiles`, which calls `alp`, which greps `$AWS_CONFIG_FILE` (default `~/.aws/config`) for `[…]` headers and strips the optional `profile ` prefix. Any new profile-taking command should be added to that `compctl` line, and the regex in `alp` is the source of truth for what counts as a valid profile name (`[-_[:alnum:]\.@]+`).
- **`asp` vs `acp` is a deliberate split.**
  - `asp` only exports `AWS_PROFILE` / `AWS_DEFAULT_PROFILE` / `AWS_EB_PROFILE` and lets the AWS SDK resolve credentials lazily.
  - `acp` additionally calls `sts assume-role` or `sts get-session-token`, handles MFA prompts (`mfa_serial`, `duration_seconds`), `role_arn`, `external_id`, `source_profile`, and exports concrete `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`. When editing `acp`, preserve the unset-on-empty-arg behavior and the fallback to `aws configure get` values when the `sts` call returns nothing.
- **Prompt injection is opt-out.** At source time the plugin prepends `$(aws_prompt_info)` to `RPROMPT` unless `SHOW_AWS_PROMPT=false` or `RPROMPT` already contains it. Don't change to an unconditional assignment — themes that set `RPROMPT` themselves rely on this guard.
- **Completer selection is order-sensitive.** AWS CLI v2's `aws_completer` is preferred; the Homebrew/Ubuntu/NixOS/RPM search for `aws_zsh_completer.sh` only runs as a fallback. New install locations should be appended to that `elif` chain rather than replacing entries.
- **Plugin header follows the [Zsh Plugin Standard](https://github.com/zdharma/Zsh-100-Commits-Club/blob/master/Zsh-Plugin-Standard.adoc).** The two-line `0=…` dance at the top resolves the plugin's own path under various loaders — don't simplify it.

## Working on the plugin

There is no automated test harness. To exercise a change:

```zsh
# In a fresh zsh, with ~/.aws/config populated:
autoload -Uz compinit && compinit
autoload -Uz bashcompinit && bashcompinit
source ./zsh-aws.plugin.zsh

alp                # list profiles
asp <profile>      # tab-completion should offer profiles from alp
agp                # echo current $AWS_PROFILE
acp <profile>      # exercise MFA / assume-role paths if applicable
```

When changing shell code, keep it POSIX-quirk-aware: this file is `zsh`-only (uses `(ps:\t:)`, `${(j:, :)…}`, `compctl`, `${0:h}`) — do not "portability-fix" it to bash.

## Conventions

- User-facing error messages go to stderr and use `${fg[red]}…${reset_color}` (see `asp`/`acp`). Match that style for new errors.
- Functions accept a single positional profile argument; calling with no argument clears state and prints a confirmation. Preserve this for any new profile-taking helper.
- `$AWS_CONFIG_FILE` must be honored with the `~/.aws/config` default expressed as `${AWS_CONFIG_FILE:-$HOME/.aws/config}` — don't hardcode the path.
