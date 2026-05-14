# Happy Coding — engineering backlog

Persistent backlog of worthwhile improvements that were **not** implemented
in the audit pass, with enough context to pick any of them up cold.

Items are grouped by ROI tier. Within a tier the order is roughly the order
I'd tackle them.

Scoring legend:

- **Priority**: `P1` material, `P2` clear win, `P3` nice-to-have, `P4` only if
  the project grows materially.
- **Effort**: rough developer-hour estimate (one person, focused).

---

## Tier 1 — high ROI, low risk

### 3. OpenSSF Scorecard workflow + badge

- **Priority**: P2
- **Effort**: ~20 min
- **Rationale**: Scorecard is the de-facto OSS-maturity baseline. For a repo
  that handles AWS credentials, having a published Scorecard score signals
  trustworthiness to downstream users. With SHA-pinning and actionlint
  already in place, this repo scores well — collect the credit.
- **What to change**: a new `.github/workflows/scorecard.yml` (the template
  from `ossf/scorecard-action`) and an
  `https://api.securityscorecards.dev/projects/...` badge in the README.
- **Implementation notes**: needs `id-token: write` and `security-events:
  write`; do those scoped at the job, not the workflow. Schedule weekly +
  on push to `main`.
- **Expected impact**: visible OSS maturity signal; surfaces regressions
  automatically.

### 4. Discussions enablement

- **Priority**: P2
- **Effort**: 5 min (one toggle in repo settings)
- **Rationale**: The new `ISSUE_TEMPLATE/config.yml` references
  `/discussions`; if Discussions isn't enabled the link 404s.
- **What to change**: Repo Settings → Features → enable Discussions, create
  the default categories.
- **Expected impact**: contributor-experience polish; cheap.

### 5. Branch protection on `main`

- **Priority**: P1
- **Effort**: 10 min
- **Rationale**: Without it, anyone with write access (or a misconfigured
  signing setup) can force-push over a tagged release. The most recent
  history rewrite was intentional but illustrates the risk.
- **What to change** (Settings → Branches → add rule for `main`):
  - require PRs (1 approval if you onboard a co-maintainer, otherwise just
    "require PR" with admin bypass off for force-pushes),
  - require status checks: `test (ubuntu-latest)`, `test (macos-latest)`,
    `codespell`, `actionlint`, and the zsh-version matrix labels,
  - require linear history,
  - require signed commits (the existing setup already SSH-signs locally),
  - block force pushes,
  - require conversation resolution.
- **Expected impact**: high — protects release integrity without slowing
  solo work meaningfully.

---

## Tier 2 — medium ROI

### 6. CodeQL — skip for now; document why

- **Priority**: P4
- **Rationale**: CodeQL does not support `zsh` (and shell support generally
  is narrow). Adding it would produce zero findings and waste minutes per
  run. The "no badge" outcome here is correct; mention it in `SECURITY.md`
  if a downstream user asks. Not worth implementing.

### 7. `shellcheck` on the test harness and the bundled completer

- **Priority**: P3
- **Effort**: ~1 hour to wire + adjust
- **Rationale**: `shellcheck` doesn't fully understand `zsh` (chokes on
  `(ps:\t:)`, `${(j:, :)…}`, `compdef`, `${0:h}`). It *does* lint
  `bin/aws_zsh_completer.sh` (bash-style) and could lint the test runner
  if we tag relevant files with `# shellcheck shell=bash` carefully.
- **Implementation notes**: a separate workflow targeting only
  `bin/aws_zsh_completer.sh`. Do **not** point it at
  `zsh-aws.plugin.zsh` — you'll bury real warnings in zsh-syntax noise.
- **Expected impact**: marginal; mostly closes a "why isn't shellcheck
  there?" reviewer question.

### 8. Cache `apt-get` in CI

- **Priority**: P4
- **Effort**: ~30 min
- **Rationale**: `sudo apt-get update && sudo apt-get install -y zsh` takes
  ~10s on hosted runners. Across 4 matrix jobs × N pushes/day that's still
  trivial. Skip unless CI minutes become a constraint.

### 9. Reuse the test job from `release.yml` via `workflow_call`

- **Priority**: P3
- **Effort**: ~30 min
- **Rationale**: `release.yml` re-implements the test job from `ci.yml`.
  Refactoring `ci.yml` into a reusable workflow eliminates the duplication
  and guarantees the release-blocking checks are identical to PR checks.
- **Implementation notes**: split the existing `test` job into
  `.github/workflows/_test.yml` with `on: workflow_call`; have both
  `ci.yml` and `release.yml` call it. Keep the matrix.
- **Expected impact**: reduces drift over time; small.

### 10. Test on Apple Silicon (`macos-14`)

- **Priority**: P3
- **Effort**: 5 min
- **Rationale**: GitHub-hosted `macos-latest` is currently arm64
  (`macos-14`), so we get this implicitly today — but pinning the matrix
  to specific versions (`macos-13` Intel + `macos-14` arm64) protects
  against the moving alias. Real-world `_aws_iso_to_epoch` BSD-date
  behavior is identical across arches, so the upside is small.

### 11. Coverage trend reporting

- **Priority**: P3
- **Effort**: ~1 hour
- **Rationale**: Coverage is currently a binary ≥80% gate. Posting the
  number as a PR comment (or to a step summary via `$GITHUB_STEP_SUMMARY`)
  gives reviewers visibility into whether a PR materially moves the needle.
- **Implementation notes**: have `coverage.zsh` emit a one-line summary to
  `$GITHUB_STEP_SUMMARY` in the CI job. Avoid third-party coverage SaaS;
  not worth the auth/setup for a shell plugin.

### 12. SLSA / signed release assets

- **Priority**: P3
- **Effort**: ~1 hour
- **Rationale**: The release workflow currently just creates a GitHub
  release from a tag; the source tarball GitHub auto-attaches is unsigned.
  For a security-adjacent project, attaching a `cosign`-signed checksum
  (`SHA256SUMS` + `SHA256SUMS.sig`) is a low-effort hardening.
- **Implementation notes**: needs `id-token: write` for keyless `cosign`.
  Pin `sigstore/cosign-installer` to a SHA (Dependabot will track bumps).

---

## Tier 3 — situational / "only if the project grows"

### 13. Conventional Commits + commitlint

- **Priority**: P4
- **Rationale**: Tiny project, one maintainer. The current "imperative
  subjects, scope: change" style produces readable auto-generated release
  notes already. Adding commitlint creates contributor friction with no
  current pain to solve. Revisit if multiple maintainers join.

### 14. release-please / semantic-release

- **Priority**: P4
- **Rationale**: Same logic. `gh release create --generate-notes` already
  produces solid notes; tags are hand-cut at release-worthy moments rather
  than on every merge. Switching to fully automated SemVer bumps via
  release-please is overkill at current cadence.

### 15. `pre-commit` framework

- **Priority**: P4
- **Rationale**: We have nothing meaningful for `pre-commit` to run yet
  (no formatter; `zsh -n` is the only lint). Skip until item #7 lands and
  there's at least one hook worth installing.

### 16. ROADMAP.md / GOVERNANCE.md

- **Priority**: P4
- **Rationale**: Single-maintainer project. Governance docs read as
  performative until there is an actual maintainer team. Skip.

### 17. Translate to a `Makefile` or `just`-file

- **Priority**: P4
- **Rationale**: Three commands (`run-tests.zsh`, `coverage.zsh`,
  `zsh -n`). A `Makefile` would add an indirection layer for no
  ergonomic gain. Skip.

### 18. AI-assistant config files

- **Priority**: P3
- **Effort**: 5 min
- **Rationale**: `CLAUDE.md` already documents architectural invariants
  for AI assistants. If you start using Cursor/Windsurf/etc., point them
  at the same file via their respective config — e.g. a
  `.cursor/rules/zsh-aws.md` that just contains
  `See [../../CLAUDE.md](../../CLAUDE.md).`
- **Expected impact**: keeps AI-assisted PRs aligned with the conventions
  in `CONTRIBUTING.md` / `CLAUDE.md`.

---

## Observations carried forward

### Technical debt

- **`_aws_iso_to_epoch` platform split**: covered by the macOS CI job, but
  if AWS ever changes the timestamp format (e.g. fractional seconds with
  more digits, or `Z` suffix variance) both branches will need an update
  in lockstep. Worth a tiny unit test that pins both code paths to
  representative inputs.
- **`mfa_command` runs under `eval`**: documented in `SECURITY.md` as
  intentional. If a future contributor proposes "let's let the AWS CLI run
  this for us instead", note that the AWS CLI's `credential_process` is
  the right escape hatch, not a refactor here.
- **The bundled `bin/aws_zsh_completer.sh`** is vendored from an
  upstream bash-completion script and is marked `linguist-vendored` in
  `.gitattributes`. If AWS CLI v2 distribution ever stops needing this
  fallback (it's been ~3 years since v2 shipped `aws_completer`), the
  entire fallback chain can be deleted, saving ~30 lines and a CI
  syntax-check step.

### Security observations

- **Credential handling**: env-var-only; never logged, never written.
  Continues to match `SECURITY.md`.
- **MFA token validation**: `^[0-9]{6}$` regex + duration bounds before
  the `sts` call. Good.
- **Profile-name validation**: `alp` accepts
  `[-_[:alnum:].@]+` only — this also bounds what reaches `aws` invocations
  as `--profile <name>`. No quoting bugs spotted.
- **Release workflow** uses default `GITHUB_TOKEN` with `contents: write`
  scoped at the workflow level. Could tighten by scoping it to the
  `release` job only, but the current shape is fine.
- **Supply chain**: the only non-trivial unpinned third-party actions are
  `codespell-project/actions-codespell` and
  `gaurav-nelson/github-action-markdown-link-check`. See item #1.

### Scalability observations

- The plugin is O(profiles) where it has to be (memoized via mtime cache),
  O(1) on the prompt path (no forking). For users with hundreds of
  profiles, `alp -v` is still O(profiles × file-reads) because
  `_aws_load_profile` re-parses both files per profile. If anyone reports
  slowness with large config files, batch-load once in `alp -v` instead.
- Nothing else has scalability concerns — it's per-shell-session state.

### Maintainability observations

- **Single-file plugin** is the right shape; resist splitting until it
  genuinely exceeds one screen of logical sections.
- **`CLAUDE.md`** carries the non-obvious invariants. Keep it updated when
  you change the `asp` vs `acp` contract, the `_aws_load_profile`
  parsing rules, the completer-fallback chain, or the prompt math.
  The CI matrix specifically protects the macOS `date` path; if you
  remove a CI row, update `CLAUDE.md` correspondingly.
