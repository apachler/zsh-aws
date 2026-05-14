# Contributing to zsh-aws

Thanks for taking the time to contribute. This document is short on purpose;
the project is small and the inner loop is fast.

## Before you start

- For anything beyond a typo fix or a one-line change, open an issue first so
  we can agree on the approach before you write the code.
- Security-sensitive findings should go through the process in
  [`SECURITY.md`](SECURITY.md), not a public issue or PR.

## Development setup

You need a working `zsh` (>= 5.8) and the AWS CLI v2 on `PATH`. The test suite
stubs out the AWS CLI, so no real AWS account is required.

```zsh
# Clone
git clone https://github.com/apachler/zsh-aws.git
cd zsh-aws

# Run the suite (fast inner loop)
zsh test/run-tests.zsh

# Run with coverage (must stay >= 80%)
zsh test/coverage.zsh

# List uncovered lines while iterating
COVERAGE_VERBOSE=1 zsh test/coverage.zsh

# Smoke-test the plugin in a clean shell
zsh -fc 'autoload -Uz compinit && compinit; \
         autoload -Uz bashcompinit && bashcompinit; \
         source ./zsh-aws.plugin.zsh; \
         alp'
```

CI runs the same suite on `ubuntu-latest`, `macos-latest`, and a matrix of
distro containers shipping zsh 5.8 / 5.8.1 / 5.9. If your change touches the
`_aws_iso_to_epoch` GNU/BSD `date` split, manually verify both arms locally
or rely on the macOS job to catch regressions.

## Project conventions

The architectural invariants and stylistic conventions live in
[`CLAUDE.md`](CLAUDE.md). They apply to human contributors too — read it
before introducing a new helper. The short version:

- One file, `zsh-aws.plugin.zsh`. Don't split it up without discussion.
- Stay `zsh`-only. We use `(ps:\t:)`, `${(j:, :)…}`, `compdef`, `${0:h}`,
  etc. Do not "portability-fix" to bash.
- Read profile data via `_aws_load_profile`, not `aws configure get`. Each
  CLI invocation costs ~150–400 ms; `acp` would call it ~9 times.
- User-facing errors go to stderr and use
  `${fg[red]}…${reset_color}`.
- Functions accept a single positional argument; calling with no argument
  clears the relevant state and prints a confirmation. Preserve this
  contract for any new helper.

## Submitting a change

1. Branch from `main`. Keep the branch name descriptive
   (e.g. `feature/asr-completion-descriptions`).
2. Make the change. Update both the README and `CLAUDE.md` if you add,
   rename, or change a command or option.
3. Run `zsh test/run-tests.zsh` and `zsh test/coverage.zsh` locally. Add or
   update assertions for the new behavior; coverage must stay ≥ 80%.
4. Commit. We don't enforce Conventional Commits, but short imperative
   subjects (`acp: detect SSO profiles…`) help the auto-generated release
   notes read well.
5. Open a PR. Link the issue you discussed, list the user-visible change,
   and call out anything you couldn't test (rare paths, BSD `date`,
   AWS CLI version differences).

## Review and merge

PRs need a green CI matrix. Maintainers may rebase or squash for a clean
history. Once merged, the change ships in the next tagged release; release
notes are auto-generated from PR titles, so write yours like a changelog
entry.

## Code of Conduct

Participating in this project means agreeing to the
[Code of Conduct](CODE_OF_CONDUCT.md).
