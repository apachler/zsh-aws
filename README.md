# ZSH AWS plugin

[![CI](https://github.com/apachler/zsh-aws/actions/workflows/ci.yml/badge.svg)](https://github.com/apachler/zsh-aws/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/apachler/zsh-aws?sort=semver)](https://github.com/apachler/zsh-aws/releases/latest)
[![License](https://img.shields.io/github/license/apachler/zsh-aws)](LICENSE)
[![zsh](https://img.shields.io/badge/zsh-5.8%2B-1A1A1A?logo=gnu-bash&logoColor=white)](https://www.zsh.org/)

This plugin is based on the original [aws plugin](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/aws) of Oh-My-ZSH!

It provides completion support for [awscli](https://docs.aws.amazon.com/cli/latest/reference/index.html)
and a few utilities to manage AWS profiles and display them in the prompt.


## Installation

First you have to enable Bash completion before loading the plugin in `~/.zshrc`

```zsh
autoload -Uz compinit && compinit
autoload -Uz bashcompinit && bashcompinit
```

Now the plugin can be loaded with any of the following methods.

### Oh My Zsh

Clone into the custom plugins directory and add to the `plugins=(...)` line in
`~/.zshrc`:

```zsh
git clone https://github.com/apachler/zsh-aws.git \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-aws"
```

```zsh
plugins=(... zsh-aws)
```

### zplug

```zsh
zplug "apachler/zsh-aws"
```

### Antigen

```zsh
antigen bundle apachler/zsh-aws
```

### Antidote

Add to your `~/.zsh_plugins.txt`:

```
apachler/zsh-aws
```

### zinit

```zsh
zinit light apachler/zsh-aws
```

For deferred loading (faster startup; load on first `aws`/`asp`/`acp` call):

```zsh
zinit ice wait lucid
zinit light apachler/zsh-aws
```

### sheldon

Add to your `~/.config/sheldon/plugins.toml`:

```toml
[plugins.zsh-aws]
github = "apachler/zsh-aws"
```

### znap

```zsh
znap source apachler/zsh-aws
```

### Manual

```zsh
git clone https://github.com/apachler/zsh-aws.git ~/.zsh-aws
echo 'source ~/.zsh-aws/zsh-aws.plugin.zsh' >> ~/.zshrc
```


## Plugin commands

* `alp [-v]`: lists the available profiles. Reads both `$AWS_CONFIG_FILE`
  (default `~/.aws/config`) and `$AWS_SHARED_CREDENTIALS_FILE` (default
  `~/.aws/credentials`) and unions the two so profiles defined only in
  credentials still show up. Results are memoized on the files' mtimes so
  repeated tab-completion stays cheap.
  - `alp -v` (or `--long`) adds `REGION` and `ROLE_ARN` columns.

* `agp`: prints the current value of `$AWS_PROFILE`.

* `agr`: prints the current value of `$AWS_REGION` (falling back to
  `$AWS_DEFAULT_REGION`).

* `asp [<profile>]`: sets `$AWS_PROFILE`, `$AWS_DEFAULT_PROFILE` (legacy) and
  `$AWS_EB_PROFILE` (Elastic Beanstalk CLI). Run `asp` with no argument to
  clear the profile.

* `asr [<region>]`: sets `$AWS_REGION` and `$AWS_DEFAULT_REGION`. Tab-completes
  against the commercial, GovCloud, and China region list. Run `asr` with no
  argument to clear.

* `acp [<profile>]`: in addition to `asp` functionality, materializes the
  profile's credentials. Supports:
  - Static IAM users (`get-session-token` with optional MFA).
  - Assumed roles via `role_arn` + `source_profile` (and `source_profile`
    chains — the AWS CLI walks them for us).
  - AWS SSO profiles (`sso_session` / `sso_start_url`): runs
    `aws sso login --profile <p>` and then `aws configure
    export-credentials` to expose `AWS_ACCESS_KEY_ID` etc. for tools that
    don't read the SSO cache.
  - `credential_source = Environment | Ec2InstanceMetadata | EcsContainer`.
  - `mfa_command = <shell command>` to fetch the MFA token non-interactively
    (e.g. `pass otp aws/prod`, `ykman oath code -s aws-dev`). When absent,
    `acp` prompts for the token with `read -rs` (no echo).

  Exports `AWS_CREDENTIAL_EXPIRATION` so the prompt can show remaining TTL.
  Run `acp` with no argument to clear all credential and profile vars.

* `acak <profile>`: rotates the AWS access key for a profile. Creates the new
  key, writes it into `~/.aws/credentials` via `aws configure set`, and
  prompts to delete the old one.

* `achain <profile>`: prints the `source_profile` chain starting at
  `<profile>`, annotated with each hop's `role_arn` / `mfa_serial` / SSO /
  `credential_source`. Detects cycles. Useful for debugging multi-account
  setups.

* `awhoami`: thin wrapper over `aws sts get-caller-identity` that prints
  ARN, account, and user-id along with the active profile and region.


## Plugin options

* `SHOW_AWS_PROMPT=false` — disables `RPROMPT` injection entirely.
* `SHOW_AWS_REGION_IN_PROMPT=false` — keeps the profile segment but drops the
  `@<region>` suffix.
* `SHOW_AWS_EXPIRY_IN_PROMPT=false` — drops the TTL segment.


## Theme

The plugin creates an `aws_prompt_info` function that you can use in your
theme. Sample output:

```
<aws:prod@us-east-1 42m>
```

Variables:

* `ZSH_THEME_AWS_PREFIX` (default `<aws:`) / `ZSH_THEME_AWS_SUFFIX` (default
  `>`) — overall wrapper.
* `ZSH_THEME_AWS_REGION_PREFIX` (default `@`) / `ZSH_THEME_AWS_REGION_SUFFIX`
  (default empty) — wrap the region segment.
* `ZSH_THEME_AWS_EXPIRY_WARN_SECS` (default `300`) — switch the TTL segment
  to the warning color when fewer seconds remain.
* `ZSH_THEME_AWS_EXPIRY_WARN_COLOR` (default `${fg[red]}`) — color used for
  the warning state and `EXPIRED`.


## Configuration

[Configuration and credential file settings](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html) by AWS

### Scenario: IAM roles with a source profile and MFA authentication

Source profile credentials in `~/.aws/credentials`:

```
[source-profile-name]
aws_access_key_id = ...
aws_secret_access_key = ...
```

Role configuration in `~/.aws/config`:

```
[profile source-profile-name]
mfa_serial = arn:aws:iam::111111111111:mfa/myuser
region = us-east-1
output = json

[profile profile-with-role]
role_arn = arn:aws:iam::9999999999999:role/myrole
mfa_serial = arn:aws:iam::111111111111:mfa/myuser
source_profile = source-profile-name
region = us-east-1
output = json
```

### Scenario: SSO

```
[sso-session corp]
sso_start_url = https://corp.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile prod]
sso_session = corp
sso_account_id = 123456789012
sso_role_name = AdministratorAccess
region = us-east-1
```

`acp prod` runs `aws sso login --profile prod` and exports the resulting
short-lived credentials via `aws configure export-credentials`.

### Scenario: non-interactive MFA via a helper

```
[profile prod]
role_arn = arn:aws:iam::999999999999:role/admin
source_profile = source
mfa_serial = arn:aws:iam::111111111111:mfa/myuser
mfa_command = pass otp aws/prod
```

`mfa_command` is run with `eval`; its stdout (stripped of whitespace) must
be the 6-digit code. Anything else fails fast before the `sts` call.


## Running the tests

```zsh
zsh test/run-tests.zsh
```

The suite uses a temporary `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE`,
exercises the plugin's public surface, and does not call the real AWS CLI.


## License

[MIT](LICENSE) © 2021 Andreas Pachler.
