#!/usr/bin/env zsh
# Smoke tests for zsh-aws. No real aws CLI is invoked: a stub on PATH covers
# the subset of `aws ...` calls the tests exercise. Run with:
#
#   zsh test/run-tests.zsh
#
# Exits non-zero on the first failed assertion.

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

# ---------- fixture setup ----------
TEST_TMP=$(mktemp -d)
cat > "$TEST_TMP/config" <<'EOF'
[default]
region = us-east-1

[profile alpha]
region = eu-west-1
role_arn = arn:aws:iam::123:role/alpha-role
source_profile = beta

[profile beta]
region = us-east-2
mfa_serial = arn:aws:iam::456:mfa/me

[profile sso-thing]
sso_session = corp
region = us-west-2

[profile cycle-a]
source_profile = cycle-b
role_arn = arn:aws:iam::999:role/a

[profile cycle-b]
source_profile = cycle-a
role_arn = arn:aws:iam::999:role/b
EOF

cat > "$TEST_TMP/credentials" <<'EOF'
[beta]
aws_access_key_id = AKIATEST
aws_secret_access_key = secret-test

[only-creds]
aws_access_key_id = AKIAOTHER
aws_secret_access_key = secret-other
EOF

export AWS_CONFIG_FILE="$TEST_TMP/config"
export AWS_SHARED_CREDENTIALS_FILE="$TEST_TMP/credentials"
export SHOW_AWS_PROMPT=false
# Avoid sourcing real ~/.aws state if any
export HOME="$TEST_TMP"

# Source plugin from the repo root
local repo_root="${0:A:h:h}"
source "$repo_root/zsh-aws.plugin.zsh"

# ---------- alp ----------
local profiles="$(alp)"
assert_contains "$profiles" "default"      "alp lists default"
assert_contains "$profiles" "alpha"        "alp lists alpha"
assert_contains "$profiles" "beta"         "alp lists beta"
assert_contains "$profiles" "only-creds"   "alp unions credentials file"

local verbose="$(alp -v)"
assert_contains "$verbose" "eu-west-1"               "alp -v shows region"
assert_contains "$verbose" "arn:aws:iam::123:role/alpha-role"  "alp -v shows role_arn"

# Memoization: second alp call should produce identical output
local profiles2="$(alp)"
assert_eq "$profiles" "$profiles2" "alp memoization stable"

# ---------- _aws_load_profile ----------
_aws_load_profile alpha
assert_eq "eu-west-1"                          "${_aws_profile_data[region]}"        "_aws_load_profile region"
assert_eq "arn:aws:iam::123:role/alpha-role"   "${_aws_profile_data[role_arn]}"      "_aws_load_profile role_arn"
assert_eq "beta"                               "${_aws_profile_data[source_profile]}" "_aws_load_profile source_profile"

_aws_load_profile beta
assert_eq "AKIATEST"  "${_aws_profile_data[aws_access_key_id]}" "_aws_load_profile reads credentials file"

# ---------- asp ----------
asp alpha >/dev/null
assert_eq "alpha" "$AWS_PROFILE"         "asp sets AWS_PROFILE"
assert_eq "alpha" "$AWS_DEFAULT_PROFILE" "asp sets AWS_DEFAULT_PROFILE"
asp >/dev/null
assert_eq "" "${AWS_PROFILE:-}" "asp with no arg clears AWS_PROFILE"

# Invalid profile must fail and not export
if asp definitely-not-a-profile >/dev/null 2>&1; then
  (( ++TESTS_RUN, ++TESTS_FAILED ))
  print -u2 "FAIL: asp with invalid profile should return non-zero"
else
  (( ++TESTS_RUN ))
fi

# ---------- asr ----------
asr us-east-1 >/dev/null
assert_eq "us-east-1" "$AWS_REGION" "asr sets AWS_REGION"
asr >/dev/null
assert_eq "" "${AWS_REGION:-}" "asr clears AWS_REGION"
if asr no-such-region >/dev/null 2>&1; then
  (( ++TESTS_RUN, ++TESTS_FAILED ))
  print -u2 "FAIL: asr with invalid region should return non-zero"
else
  (( ++TESTS_RUN ))
fi

# ---------- aws_prompt_info ----------
unset AWS_PROFILE
assert_eq "" "$(aws_prompt_info)" "no prompt without AWS_PROFILE"

export AWS_PROFILE=alpha
assert_eq "<aws:alpha>" "$(aws_prompt_info)" "prompt with profile only"

export AWS_REGION=eu-west-1
assert_eq "<aws:alpha@eu-west-1>" "$(aws_prompt_info)" "prompt with profile+region"

export _AWS_CREDENTIAL_EXPIRATION_EPOCH=$(( EPOCHSECONDS + 1800 ))
assert_contains "$(aws_prompt_info)" "30m" "prompt shows TTL"

export _AWS_CREDENTIAL_EXPIRATION_EPOCH=$(( EPOCHSECONDS - 60 ))
assert_contains "$(aws_prompt_info)" "EXPIRED" "prompt shows EXPIRED"

unset _AWS_CREDENTIAL_EXPIRATION_EPOCH AWS_REGION AWS_PROFILE

# ---------- achain ----------
local chain="$(achain alpha 2>&1)"
assert_contains "$chain" "alpha"  "achain shows starting profile"
assert_contains "$chain" "beta"   "achain follows source_profile"

# Cycle detection
if achain cycle-a >/dev/null 2>&1; then
  (( ++TESTS_RUN, ++TESTS_FAILED ))
  print -u2 "FAIL: achain should detect cycle and return non-zero"
else
  (( ++TESTS_RUN ))
fi

# ---------- _aws_iso_to_epoch ----------
local epoch
epoch="$(_aws_iso_to_epoch "2030-01-01T00:00:00Z")"
assert_eq "1893456000" "$epoch" "_aws_iso_to_epoch parses ISO 8601"

# ---------- summary ----------
print ""
if (( TESTS_FAILED == 0 )); then
  print "All $TESTS_RUN tests passed."
  exit 0
else
  print -u2 "$TESTS_FAILED of $TESTS_RUN tests failed."
  exit 1
fi
