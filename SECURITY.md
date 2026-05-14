# Security Policy

`zsh-aws` is a shell plugin that handles AWS credentials in your interactive
shell. It runs entirely on your machine, never transmits credentials anywhere,
and depends only on the AWS CLI you already use. Even so, anything that touches
credentials deserves careful review.

## Supported versions

Only the latest tagged release receives security fixes. Older tags are not
backported. If you depend on this plugin, pin to a tag and update on a cadence
that fits your environment.

## Reporting a vulnerability

**Please do not open a public GitHub issue for suspected security problems.**

Report privately via GitHub's
[private vulnerability reporting](https://github.com/apachler/zsh-aws/security/advisories/new)
(`Security` tab → `Report a vulnerability`).

When you report, include:

- a description of the issue and its impact,
- the version (commit SHA or tag) you reproduced it against,
- minimal reproduction steps,
- whether AWS credentials, MFA tokens, or session cookies are exposed in any
  way, and
- your suggested fix, if any.

You will receive an acknowledgement within **3 business days** and a status
update at least every **7 days** until the issue is resolved.

## Scope

In scope:

- credential leakage (env vars printed to stdout, written to a file, or sent
  off-host),
- command injection via profile names, `mfa_command`, `role_session_name`,
  region inputs, or any other field read from `~/.aws/config` /
  `~/.aws/credentials`,
- privilege escalation paths inside the plugin itself,
- supply-chain risks in the release workflow (tag/asset tampering).

Out of scope:

- vulnerabilities in the AWS CLI itself — report those to AWS,
- vulnerabilities in plugin managers (`zinit`, `zplug`, `antidote`, `znap`,
  `sheldon`, Antigen, Oh My Zsh) — report those upstream,
- weaknesses in your local `~/.aws/` file permissions — that is an operator
  configuration concern.

## Handling AWS credentials

A few operating principles to set expectations:

- The plugin reads `~/.aws/config` and `~/.aws/credentials` only; it never
  writes secrets to the shell history, never logs them, and never sends them
  over the network.
- `acp`'s SSO path invokes the AWS CLI to obtain short-lived credentials and
  exports them as env vars in your current shell only.
- `mfa_command` (when configured) is invoked via `eval`, so the command line
  is fully under your control. Do not put untrusted strings there.
- MFA tokens are read with `read -rs` (no echo) and validated against
  `^[0-9]{6}$` before being passed to `sts`.
- `_AWS_CREDENTIAL_EXPIRATION_EPOCH` is a sidecar env var used by
  `aws_prompt_info` for cheap TTL math. It contains no secret material.

If you find a deviation from any of the above, that is in scope.
