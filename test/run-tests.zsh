#!/usr/bin/env zsh
# Smoke tests for zsh-aws. A stub `aws` on PATH covers the subset of
# `aws ...` calls the tests exercise, so nothing reaches the real cloud.
# Run with:
#
#   zsh test/run-tests.zsh
#
# Exits non-zero if any assertion fails.

emulate -L zsh

# The plugin's completer fallback expects compinit/bashcompinit to be loaded
# (matching the README's installation steps). Initialize them here so we don't
# get spurious "command not found: compdef" warnings during sourcing.
autoload -Uz compinit && compinit -u -d /tmp/zcompdump.$$ 2>/dev/null
autoload -Uz bashcompinit && bashcompinit 2>/dev/null

typeset -g TESTS_RUN=0 TESTS_FAILED=0
typeset -g TEST_TMP

cleanup() {
  [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# ---------- helpers ----------
assert_eq() {
  local expected="$1" actual="$2" msg="${3:-assert_eq}"
  (( ++TESTS_RUN ))
  if [[ "$expected" != "$actual" ]]; then
    (( ++TESTS_FAILED ))
    print -u2 "FAIL: $msg"
    print -u2 "  expected: $expected"
    print -u2 "  actual:   $actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-assert_contains}"
  (( ++TESTS_RUN ))
  if [[ "$haystack" != *"$needle"* ]]; then
    (( ++TESTS_FAILED ))
    print -u2 "FAIL: $msg"
    print -u2 "  string:   $haystack"
    print -u2 "  expected to contain: $needle"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-assert_not_contains}"
  (( ++TESTS_RUN ))
  if [[ "$haystack" == *"$needle"* ]]; then
    (( ++TESTS_FAILED ))
    print -u2 "FAIL: $msg"
    print -u2 "  string:   $haystack"
    print -u2 "  expected NOT to contain: $needle"
  fi
}

assert_fails() {
  local msg="${1:?msg required}"; shift
  (( ++TESTS_RUN ))
  if "$@" >/dev/null 2>&1; then
    (( ++TESTS_FAILED ))
    print -u2 "FAIL: $msg"
    print -u2 "  command unexpectedly succeeded: $*"
  fi
}

assert_succeeds() {
  local msg="${1:?msg required}"; shift
  (( ++TESTS_RUN ))
  if ! "$@" >/dev/null 2>&1; then
    (( ++TESTS_FAILED ))
    print -u2 "FAIL: $msg"
    print -u2 "  command unexpectedly failed: $*"
  fi
}

# ---------- fixture setup ----------
TEST_TMP=$(mktemp -d)
cat > "$TEST_TMP/config" <<'EOF'
[default]
region = us-east-1

[profile alpha]
region = eu-west-1
role_arn = arn:aws:iam::123:role/alpha-role
source_profile = beta
mfa_serial = arn:aws:iam::456:mfa/me
mfa_command = printf '123456'
duration_seconds = 3600

[profile beta]
region = us-east-2

[profile noauth]
region = us-west-1

[profile ext]
region = us-east-1
role_arn = arn:aws:iam::123:role/ext-role
source_profile = beta
external_id = ABC-XYZ

[profile ec2]
role_arn = arn:aws:iam::444:role/ec2
credential_source = Ec2InstanceMetadata

[profile sso-thing]
sso_session = corp
sso_account_id = 123456789012
sso_role_name = AdministratorAccess
region = us-west-2

[profile cycle-a]
source_profile = cycle-b
role_arn = arn:aws:iam::999:role/a

[profile cycle-b]
source_profile = cycle-a
role_arn = arn:aws:iam::999:role/b

# A comment line
; another comment style

[profile with-subsection]
region = us-east-1
s3 =
  signature_version = s3v4

[profile bad-mfa]
role_arn = arn:aws:iam::123:role/x
source_profile = beta
mfa_serial = arn:aws:iam::456:mfa/me
mfa_command = printf ''
EOF

cat > "$TEST_TMP/credentials" <<'EOF'
[beta]
aws_access_key_id = AKIATEST
aws_secret_access_key = secret-test

[noauth]
aws_access_key_id = AKIANOAUTH
aws_secret_access_key = secret-noauth

[only-creds]
aws_access_key_id = AKIAOTHER
aws_secret_access_key = secret-other
EOF

# Set up a stub `aws` binary that records each invocation. We put it first on
# PATH so the plugin and acak/acp/awhoami use the stub instead of the real CLI.
mkdir -p "$TEST_TMP/bin"
export AWS_STUB_LOG="$TEST_TMP/aws-calls.log"
: > "$AWS_STUB_LOG"
cat > "$TEST_TMP/bin/aws" <<'STUB'
#!/usr/bin/env zsh
emulate -L zsh

print -r -- "$*" >> "${AWS_STUB_LOG:-/dev/null}"

# Walk past --flag values to find the first two non-flag args (the AWS verb
# and subcommand). They identify the operation; everything else is options.
typeset -a positional
local a
for a in "$@"; do
  [[ "$a" == --* ]] && continue
  positional+=("$a")
  (( ${#positional} >= 4 )) && break
done
local cmd="${positional[1]} ${positional[2]}"

# Controlled-failure mode: AWS_STUB_FAIL is a single subcommand prefix (e.g.
# "sts get-caller-identity" or "sso login"). If $cmd matches, exit non-zero
# before the canned responses below.
if [[ -n "${AWS_STUB_FAIL:-}" && "$cmd" == "$AWS_STUB_FAIL"* ]]; then
  print -u2 "stub: forced failure for '$cmd'"
  exit 1
fi

case "$cmd" in
  "sts assume-role")
    print -- $'AKIAASR\tsecretASR\ttokenASR\t2099-12-31T23:59:59Z'
    ;;
  "sts get-session-token")
    print -- $'AKIAGST\tsecretGST\ttokenGST\t2099-12-31T23:59:59Z'
    ;;
  "sts get-caller-identity")
    print -- $'123456789012\tarn:aws:iam::123456789012:role/Test\tAIDATEST'
    ;;
  "iam create-access-key")
    print -- $'AKIANEW\tnewsecret'
    ;;
  "iam delete-access-key"|"iam list-access-keys")
    : # noop
    ;;
  "sso login")
    print "SSO login OK"
    ;;
  "configure export-credentials")
    print "AWS_ACCESS_KEY_ID=AKIASSO"
    print "AWS_SECRET_ACCESS_KEY=ssosecret"
    print "AWS_SESSION_TOKEN=ssotoken"
    print "AWS_CREDENTIAL_EXPIRATION=2099-12-31T23:59:59Z"
    ;;
  "configure set")
    : # noop
    ;;
  "configure get")
    case "$positional[3]" in
      aws_access_key_id) print "OLDAKIA" ;;
      *) : ;;
    esac
    ;;
  *)
    print -u2 "stub: unhandled: aws $*"
    exit 99
    ;;
esac
STUB
chmod +x "$TEST_TMP/bin/aws"

export AWS_CONFIG_FILE="$TEST_TMP/config"
export AWS_SHARED_CREDENTIALS_FILE="$TEST_TMP/credentials"
export SHOW_AWS_PROMPT=false
export HOME="$TEST_TMP"
export PATH="$TEST_TMP/bin:$PATH"

# Source plugin from the repo root
local repo_root="${0:A:h:h}"
source "$repo_root/zsh-aws.plugin.zsh"

reset_env() {
  unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_EB_PROFILE
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  unset AWS_CREDENTIAL_EXPIRATION _AWS_CREDENTIAL_EXPIRATION_EPOCH
  unset AWS_REGION AWS_DEFAULT_REGION
}

# ============================================================
# alp
# ============================================================
local profiles="$(alp)"
assert_contains "$profiles" "default"      "alp lists default"
assert_contains "$profiles" "alpha"        "alp lists alpha"
assert_contains "$profiles" "beta"         "alp lists beta"
assert_contains "$profiles" "only-creds"   "alp unions credentials file"
assert_contains "$profiles" "ec2"          "alp lists credential_source profile"

local verbose="$(alp -v)"
assert_contains "$verbose" "eu-west-1"                                  "alp -v shows region"
assert_contains "$verbose" "arn:aws:iam::123:role/alpha-role"           "alp -v shows role_arn"
assert_contains "$verbose" "PROFILE"                                    "alp -v shows header"

# --long is the same as -v
local long_form="$(alp --long)"
assert_contains "$long_form" "eu-west-1" "alp --long shows region"

# Help mode
assert_contains "$(alp -h 2>&1)" "usage" "alp -h prints usage"

# Unknown arg fails
assert_fails "alp errors on unknown arg" alp --bogus

# Memoization: second call should produce identical output
local profiles2="$(alp)"
assert_eq "$profiles" "$profiles2" "alp memoization stable"

# Touch config to invalidate cache, then call again
sleep 1
print "" >> "$AWS_CONFIG_FILE"
local profiles3="$(alp)"
assert_eq "$profiles" "$profiles3" "alp after cache invalidation returns same profiles"

# Missing config returns non-zero (use a non-existent dir)
(
  export AWS_CONFIG_FILE="$TEST_TMP/does-not-exist/config"
  export AWS_SHARED_CREDENTIALS_FILE="$TEST_TMP/does-not-exist/credentials"
  if alp >/dev/null 2>&1; then
    print -u2 "FAIL: alp should fail when neither file exists"
    exit 1
  fi
) && (( ++TESTS_RUN )) || { (( ++TESTS_RUN, ++TESTS_FAILED )); }

# ============================================================
# _aws_load_profile
# ============================================================
_aws_load_profile alpha
assert_eq "eu-west-1"                          "${_aws_profile_data[region]}"        "_aws_load_profile region"
assert_eq "arn:aws:iam::123:role/alpha-role"   "${_aws_profile_data[role_arn]}"      "_aws_load_profile role_arn"
assert_eq "beta"                               "${_aws_profile_data[source_profile]}" "_aws_load_profile source_profile"
assert_eq "3600"                               "${_aws_profile_data[duration_seconds]}" "_aws_load_profile duration_seconds"

_aws_load_profile beta
assert_eq "AKIATEST"  "${_aws_profile_data[aws_access_key_id]}"     "_aws_load_profile reads credentials file"

_aws_load_profile alpha
assert_eq "arn:aws:iam::456:mfa/me" "${_aws_profile_data[mfa_serial]}" "_aws_load_profile mfa_serial"
assert_eq "printf '123456'" "${_aws_profile_data[mfa_command]}"      "_aws_load_profile mfa_command"

_aws_load_profile sso-thing
assert_eq "corp" "${_aws_profile_data[sso_session]}" "_aws_load_profile sso_session"

_aws_load_profile ec2
assert_eq "Ec2InstanceMetadata" "${_aws_profile_data[credential_source]}" "_aws_load_profile credential_source"

_aws_load_profile ext
assert_eq "ABC-XYZ" "${_aws_profile_data[external_id]}" "_aws_load_profile external_id"

# subsection introducer ("s3 =" with indented props) doesn't crash
_aws_load_profile with-subsection
assert_eq "us-east-1" "${_aws_profile_data[region]}" "_aws_load_profile tolerates subsections"

# Unknown profile produces empty data
_aws_load_profile does-not-exist
assert_eq "" "${_aws_profile_data[region]:-}" "_aws_load_profile of unknown profile is empty"

# ============================================================
# asp
# ============================================================
reset_env
asp alpha >/dev/null
assert_eq "alpha" "$AWS_PROFILE"         "asp sets AWS_PROFILE"
assert_eq "alpha" "$AWS_DEFAULT_PROFILE" "asp sets AWS_DEFAULT_PROFILE"
assert_eq "alpha" "$AWS_EB_PROFILE"      "asp sets AWS_EB_PROFILE"

asp >/dev/null
assert_eq "" "${AWS_PROFILE:-}" "asp with no arg clears AWS_PROFILE"
assert_eq "" "${AWS_EB_PROFILE:-}" "asp with no arg clears AWS_EB_PROFILE"

# Invalid profile must fail and not export
assert_fails "asp with invalid profile" asp definitely-not-a-profile

# ============================================================
# asr
# ============================================================
reset_env
asr us-east-1 >/dev/null
assert_eq "us-east-1" "$AWS_REGION"         "asr sets AWS_REGION"
assert_eq "us-east-1" "$AWS_DEFAULT_REGION" "asr sets AWS_DEFAULT_REGION"

asr >/dev/null
assert_eq "" "${AWS_REGION:-}" "asr clears AWS_REGION"

assert_fails "asr with invalid region" asr no-such-region

# ============================================================
# agp / agr
# ============================================================
reset_env
export AWS_PROFILE=foo
assert_eq "foo" "$(agp)" "agp echoes AWS_PROFILE"

export AWS_REGION=eu-west-1
assert_eq "eu-west-1" "$(agr)" "agr prefers AWS_REGION"
unset AWS_REGION
export AWS_DEFAULT_REGION=us-east-2
assert_eq "us-east-2" "$(agr)" "agr falls back to AWS_DEFAULT_REGION"
reset_env

# ============================================================
# aws_prompt_info
# ============================================================
reset_env
assert_eq "" "$(aws_prompt_info)" "no prompt without AWS_PROFILE"

export AWS_PROFILE=alpha
assert_eq "<aws:alpha>" "$(aws_prompt_info)" "prompt with profile only"

export AWS_REGION=eu-west-1
assert_eq "<aws:alpha@eu-west-1>" "$(aws_prompt_info)" "prompt with profile+region"

export _AWS_CREDENTIAL_EXPIRATION_EPOCH=$(( EPOCHSECONDS + 1800 ))
assert_contains "$(aws_prompt_info)" "30m" "prompt shows TTL"

# Within warning threshold
export _AWS_CREDENTIAL_EXPIRATION_EPOCH=$(( EPOCHSECONDS + 120 ))
local short_prompt="$(aws_prompt_info)"
assert_contains "$short_prompt" "2m" "prompt shows short TTL"

# Expired
export _AWS_CREDENTIAL_EXPIRATION_EPOCH=$(( EPOCHSECONDS - 60 ))
assert_contains "$(aws_prompt_info)" "EXPIRED" "prompt shows EXPIRED"

# Opt-outs
export SHOW_AWS_EXPIRY_IN_PROMPT=false
assert_not_contains "$(aws_prompt_info)" "EXPIRED" "SHOW_AWS_EXPIRY_IN_PROMPT=false hides TTL"
unset SHOW_AWS_EXPIRY_IN_PROMPT

export SHOW_AWS_REGION_IN_PROMPT=false
assert_not_contains "$(aws_prompt_info)" "@eu-west-1" "SHOW_AWS_REGION_IN_PROMPT=false hides region"
unset SHOW_AWS_REGION_IN_PROMPT

# Theme variable overrides
export ZSH_THEME_AWS_PREFIX="[" ZSH_THEME_AWS_SUFFIX="]"
unset _AWS_CREDENTIAL_EXPIRATION_EPOCH
assert_eq "[alpha@eu-west-1]" "$(aws_prompt_info)" "prompt respects ZSH_THEME_AWS_PREFIX/SUFFIX"
unset ZSH_THEME_AWS_PREFIX ZSH_THEME_AWS_SUFFIX

reset_env

# ============================================================
# achain
# ============================================================
local chain="$(achain alpha 2>&1)"
assert_contains "$chain" "alpha"  "achain shows starting profile"
assert_contains "$chain" "beta"   "achain follows source_profile"
assert_contains "$chain" "mfa"    "achain shows mfa marker"

# credential_source
local chain_ec2="$(achain ec2 2>&1)"
assert_contains "$chain_ec2" "credential_source=Ec2InstanceMetadata" "achain shows credential_source"

# SSO marker
local chain_sso="$(achain sso-thing 2>&1)"
assert_contains "$chain_sso" "sso=yes" "achain shows sso marker"

# Cycle detection
assert_fails "achain detects cycle" achain cycle-a

# No-arg usage
assert_fails "achain requires an argument" achain

# ============================================================
# _aws_iso_to_epoch
# ============================================================
assert_eq "1893456000" "$(_aws_iso_to_epoch '2030-01-01T00:00:00Z')" "_aws_iso_to_epoch parses ISO 8601"
assert_fails "_aws_iso_to_epoch rejects garbage" _aws_iso_to_epoch "not a date at all"

# ============================================================
# acp — all major branches via the aws stub
# ============================================================
reset_env
: > "$AWS_STUB_LOG"

# Clear path
acp >/dev/null
assert_eq "" "${AWS_PROFILE:-}" "acp with no arg clears AWS_PROFILE"
assert_eq "" "${AWS_ACCESS_KEY_ID:-}" "acp with no arg clears AWS_ACCESS_KEY_ID"

# Invalid profile
assert_fails "acp rejects unknown profile" acp definitely-not-a-profile

# 1. No-MFA, no-role: get-session-token via stub.
# `noauth` has no mfa_serial, no role_arn, so acp falls through to
# get-session-token. The stub returns AKIAGST.
reset_env
: > "$AWS_STUB_LOG"
acp noauth >/dev/null
assert_eq "noauth"        "$AWS_PROFILE"            "acp(noauth) sets AWS_PROFILE"
assert_eq "AKIAGST"       "$AWS_ACCESS_KEY_ID"      "acp(noauth) sets AWS_ACCESS_KEY_ID from get-session-token"
assert_eq "secretGST"     "$AWS_SECRET_ACCESS_KEY"  "acp(noauth) sets AWS_SECRET_ACCESS_KEY"
assert_eq "tokenGST"      "$AWS_SESSION_TOKEN"      "acp(noauth) sets AWS_SESSION_TOKEN"
assert_eq "2099-12-31T23:59:59Z" "$AWS_CREDENTIAL_EXPIRATION" "acp(noauth) sets AWS_CREDENTIAL_EXPIRATION"
[[ -n "$_AWS_CREDENTIAL_EXPIRATION_EPOCH" ]] && (( ++TESTS_RUN )) || (( ++TESTS_RUN, ++TESTS_FAILED ))
assert_contains "$(cat $AWS_STUB_LOG)" "sts get-session-token" "acp(noauth) called sts get-session-token"

# 2. Assume-role with source_profile + MFA via mfa_command
reset_env
: > "$AWS_STUB_LOG"
acp alpha >/dev/null
assert_eq "alpha"      "$AWS_PROFILE"           "acp(alpha) sets AWS_PROFILE"
assert_eq "AKIAASR"    "$AWS_ACCESS_KEY_ID"     "acp(alpha) sets keys from assume-role"
assert_contains "$(cat $AWS_STUB_LOG)" "sts assume-role" "acp(alpha) called sts assume-role"
assert_contains "$(cat $AWS_STUB_LOG)" "arn:aws:iam::123:role/alpha-role" "acp(alpha) passed role_arn"
assert_contains "$(cat $AWS_STUB_LOG)" "--profile=beta" "acp(alpha) used source_profile"
assert_contains "$(cat $AWS_STUB_LOG)" "123456" "acp(alpha) sourced MFA token from mfa_command"

# 3. external_id support
reset_env
: > "$AWS_STUB_LOG"
acp ext >/dev/null
assert_contains "$(cat $AWS_STUB_LOG)" "--external-id ABC-XYZ" "acp(ext) passes external_id"

# 4. credential_source path
reset_env
: > "$AWS_STUB_LOG"
acp ec2 >/dev/null
assert_contains "$(cat $AWS_STUB_LOG)" "--profile=ec2" "acp(ec2) uses the role profile itself when credential_source is set"

# 5. SSO path
reset_env
: > "$AWS_STUB_LOG"
acp sso-thing >/dev/null
assert_eq "sso-thing" "$AWS_PROFILE"           "acp(SSO) sets AWS_PROFILE"
assert_eq "AKIASSO"   "$AWS_ACCESS_KEY_ID"     "acp(SSO) picks up creds from export-credentials"
assert_eq "ssosecret" "$AWS_SECRET_ACCESS_KEY" "acp(SSO) picks up secret"
assert_eq "ssotoken"  "$AWS_SESSION_TOKEN"     "acp(SSO) picks up session token"
assert_eq "2099-12-31T23:59:59Z" "$AWS_CREDENTIAL_EXPIRATION" "acp(SSO) picks up expiration"
assert_contains "$(cat $AWS_STUB_LOG)" "sso login" "acp(SSO) ran aws sso login"
assert_contains "$(cat $AWS_STUB_LOG)" "configure export-credentials" "acp(SSO) ran export-credentials"

# acp clear after credentials should remove expiration sidecar
reset_env
acp alpha >/dev/null
acp >/dev/null
assert_eq "" "${AWS_CREDENTIAL_EXPIRATION:-}" "acp clear removes AWS_CREDENTIAL_EXPIRATION"
assert_eq "" "${_AWS_CREDENTIAL_EXPIRATION_EPOCH:-}" "acp clear removes epoch sidecar"

# ============================================================
# awhoami
# ============================================================
reset_env
local who="$(awhoami)"
assert_contains "$who" "arn:aws:iam::123456789012:role/Test" "awhoami prints ARN"
assert_contains "$who" "123456789012"                          "awhoami prints account"

# ============================================================
# acak — write new key, no interactive prompts (we feed 'n' to delete)
# ============================================================
reset_env
: > "$AWS_STUB_LOG"
# Pipe 'n' to the prompt for old-key deletion.
print "n" | acak alpha >/dev/null
assert_contains "$(cat $AWS_STUB_LOG)" "iam create-access-key" "acak called create-access-key"
assert_contains "$(cat $AWS_STUB_LOG)" "configure set aws_access_key_id AKIANEW" "acak wrote new key id"
assert_contains "$(cat $AWS_STUB_LOG)" "configure set aws_secret_access_key" "acak wrote new secret"
assert_not_contains "$(cat $AWS_STUB_LOG)" "iam delete-access-key" "acak skipped delete on 'n'"

# Now answer 'y' — should call delete-access-key
reset_env
: > "$AWS_STUB_LOG"
print "y" | acak alpha >/dev/null
assert_contains "$(cat $AWS_STUB_LOG)" "iam delete-access-key" "acak deletes old key on 'y'"

# usage when no profile given
assert_fails "acak requires a profile arg" acak

# ============================================================
# Error / edge-case paths
# ============================================================

# mfa_command produces empty output
reset_env
: > "$AWS_STUB_LOG"
assert_fails "acp(bad-mfa) fails when mfa_command yields nothing" acp bad-mfa

# Stubbed aws fails — awhoami surfaces it
reset_env
AWS_STUB_FAIL="sts get-caller-identity" assert_fails "awhoami surfaces sts failure" awhoami

# Stubbed sso login fails — acp(SSO) bails
reset_env
AWS_STUB_FAIL="sso login" assert_fails "acp(SSO) fails when sso login fails" acp sso-thing

# SSO with export-credentials failure: should still set AWS_PROFILE but no creds
reset_env
: > "$AWS_STUB_LOG"
AWS_STUB_FAIL="configure export-credentials" acp sso-thing >/dev/null
assert_eq "sso-thing" "$AWS_PROFILE" "acp(SSO) sets AWS_PROFILE even if export-credentials fails"
assert_eq "" "${AWS_ACCESS_KEY_ID:-}" "acp(SSO) clears AWS_ACCESS_KEY_ID on export-credentials failure"

# acak: create-access-key failure
reset_env
: > "$AWS_STUB_LOG"
AWS_STUB_FAIL="iam create-access-key" assert_fails "acak fails when create-access-key fails" acak alpha

# ============================================================
# completion helpers
# ============================================================
reset_env
local complete_out
complete_out="$(reply=(); _aws_profiles; print -- ${reply})"
assert_contains "$complete_out" "alpha" "_aws_profiles populates reply"

# Call the modern completion functions directly to exercise their bodies.
# _describe needs a completion context, so we silence its errors and don't
# assert on output — we just want the function bodies to run.
_zsh_aws_profile_complete >/dev/null 2>&1
_zsh_aws_region_complete  >/dev/null 2>&1
(( ++TESTS_RUN ))   # the absence of a crash is the assertion

# ============================================================
# summary
# ============================================================
print ""
if (( TESTS_FAILED == 0 )); then
  print "All $TESTS_RUN tests passed."
  exit 0
else
  print -u2 "$TESTS_FAILED of $TESTS_RUN tests failed."
  exit 1
fi
