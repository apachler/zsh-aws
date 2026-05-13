#!/usr/bin/env zsh
# Standarized $0 handling, following:
# https://github.com/zdharma/Zsh-100-Commits-Club/blob/master/Zsh-Plugin-Standard.adoc
0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"

if [[ $PMSPEC != *b* ]] {
  PATH=$PATH:"${0:h}/bin"
}

# $EPOCHSECONDS is used by aws_prompt_info for cheap TTL math without forking.
zmodload zsh/datetime 2>/dev/null


function alp() {
  local verbose=0 arg
  for arg in "$@"; do
    case "$arg" in
      -v|--long|--verbose) verbose=1 ;;
      -h|--help)
        echo "usage: alp [-v|--long]   # list AWS profiles (verbose adds region and role_arn)"
        return 0
        ;;
      *) echo "alp: unknown argument: $arg" >&2; return 2 ;;
    esac
  done

  local config="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  local creds="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"

  # Cheap cache invalidation key: file paths + mtimes. Re-stat is cheaper than
  # re-parsing a config with dozens of profiles on every tab press.
  zmodload -F zsh/stat b:zstat 2>/dev/null
  local -a stat_result
  local config_mtime=0 creds_mtime=0
  [[ -r "$config" ]] && zstat -A stat_result +mtime "$config" 2>/dev/null && config_mtime="$stat_result[1]"
  [[ -r "$creds" ]] && zstat -A stat_result +mtime "$creds" 2>/dev/null && creds_mtime="$stat_result[1]"
  local cache_key="$config:$config_mtime:$creds:$creds_mtime"

  typeset -gA _aws_alp_cache
  if (( ! verbose )) && [[ "${_aws_alp_cache[key]}" == "$cache_key" && -n "${_aws_alp_cache[list]}" ]]; then
    print -r -- "${_aws_alp_cache[list]}"
    return 0
  fi

  local file line section
  local -A seen
  local -a profiles
  for file in "$config" "$creds"; do
    [[ -r "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      if [[ $line =~ '^[[:space:]]*\[[[:space:]]*(profile[[:space:]]+)?([-_[:alnum:].@]+)[[:space:]]*\][[:space:]]*$' ]]; then
        section="$match[2]"
        if [[ -z "${seen[$section]}" ]]; then
          seen[$section]=1
          profiles+=("$section")
        fi
      fi
    done < "$file"
  done

  (( ${#profiles} )) || return 1

  if (( verbose )); then
    local p region role
    printf "%-32s %-16s %s\n" "PROFILE" "REGION" "ROLE_ARN"
    for p in "${profiles[@]}"; do
      _aws_load_profile "$p"
      region="${_aws_profile_data[region]:--}"
      role="${_aws_profile_data[role_arn]:--}"
      printf "%-32s %-16s %s\n" "$p" "$region" "$role"
    done
    return 0
  fi

  local list="${(F)profiles}"
  _aws_alp_cache[key]="$cache_key"
  _aws_alp_cache[list]="$list"
  print -r -- "$list"
}

# Load all keys for $1 from $AWS_CONFIG_FILE and the credentials file into the
# associative array _aws_profile_data, replacing 9+ slow `aws configure get`
# subprocesses with two flat reads. Honors `profile NAME` (config) vs `NAME`
# (credentials) section conventions.
function _aws_load_profile() {
  local profile="$1"
  local file line key value section in_section

  typeset -gA _aws_profile_data
  _aws_profile_data=()

  for file in "${AWS_CONFIG_FILE:-$HOME/.aws/config}" \
              "${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"; do
    [[ -r "$file" ]] || continue
    in_section=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      if [[ $line =~ '^[[:space:]]*\[[[:space:]]*(profile[[:space:]]+)?([-_[:alnum:].@]+)[[:space:]]*\][[:space:]]*$' ]]; then
        section="$match[2]"
        [[ "$section" == "$profile" ]] && in_section=1 || in_section=0
        continue
      fi
      (( in_section )) || continue
      # key = value; skip subsection introducers ("s3 =" with indented kids)
      if [[ $line =~ '^[[:space:]]*([^=[:space:]]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]]|)[[:space:]]*$' ]]; then
        key="$match[1]"
        value="$match[2]"
        [[ -z "$value" ]] && continue
        _aws_profile_data[$key]="$value"
      fi
    done < "$file"
  done
}

function agp() {
  echo $AWS_PROFILE
}

# Static list of AWS commercial + GovCloud + China regions. The plugin doesn't
# call out to EC2 to enumerate regions because that would (a) require valid
# credentials and (b) be too slow for tab-completion.
typeset -gra _AWS_REGIONS=(
  us-east-1 us-east-2 us-west-1 us-west-2
  af-south-1
  ap-east-1 ap-south-1 ap-south-2
  ap-northeast-1 ap-northeast-2 ap-northeast-3
  ap-southeast-1 ap-southeast-2 ap-southeast-3 ap-southeast-4 ap-southeast-5
  ca-central-1 ca-west-1
  eu-central-1 eu-central-2
  eu-north-1 eu-south-1 eu-south-2
  eu-west-1 eu-west-2 eu-west-3
  il-central-1
  me-central-1 me-south-1
  sa-east-1
  us-gov-east-1 us-gov-west-1
  cn-north-1 cn-northwest-1
)

# AWS region selection
function asr() {
  if [[ -z "$1" ]]; then
    unset AWS_REGION AWS_DEFAULT_REGION
    echo AWS region cleared.
    return
  fi

  if [[ -z "${_AWS_REGIONS[(r)$1]}" ]]; then
    echo "${fg[red]}Region '$1' is not a known AWS region.${reset_color}" >&2
    echo "Known regions: ${(j:, :)_AWS_REGIONS}" >&2
    return 1
  fi

  export AWS_REGION="$1"
  export AWS_DEFAULT_REGION="$1"
}

function agr() {
  echo "${AWS_REGION:-$AWS_DEFAULT_REGION}"
}

# Print the resolved AWS identity (account, user/role ARN) for the current
# environment. Thin wrapper over `aws sts get-caller-identity` with a stable,
# one-line output suitable for shell scripting.
function awhoami() {
  local out
  if ! out="$(aws sts get-caller-identity --output text --query '[Account,Arn,UserId]' 2>&1)"; then
    echo "${fg[red]}awhoami: $out${reset_color}" >&2
    return 1
  fi
  local -a parts
  parts=(${(ps:\t:)out})
  local account="${parts[1]}" arn="${parts[2]}" user_id="${parts[3]}"
  local profile_segment=""
  [[ -n "$AWS_PROFILE" ]] && profile_segment=" (profile: $AWS_PROFILE)"
  local region="${AWS_REGION:-$AWS_DEFAULT_REGION}"
  [[ -n "$region" ]] && profile_segment+=" [region: $region]"
  echo "$arn"
  echo "  account: $account"
  echo "  user-id: $user_id$profile_segment"
}

# AWS profile selection
function asp() {
  if [[ -z "$1" ]]; then
    unset AWS_DEFAULT_PROFILE AWS_PROFILE AWS_EB_PROFILE
    unset AWS_CREDENTIAL_EXPIRATION _AWS_CREDENTIAL_EXPIRATION_EPOCH
    echo AWS profile cleared.
    return
  fi

  local -a available_profiles
  available_profiles=($(alp))
  if [[ -z "${available_profiles[(r)$1]}" ]]; then
    echo "${fg[red]}Profile '$1' not found in '${AWS_CONFIG_FILE:-$HOME/.aws/config}'" >&2
    echo "Available profiles: ${(j:, :)available_profiles:-no profiles found}${reset_color}" >&2
    return 1
  fi

  export AWS_DEFAULT_PROFILE=$1
  export AWS_PROFILE=$1
  export AWS_EB_PROFILE=$1
}

# Convert an ISO-8601 timestamp (as returned by sts and export-credentials)
# to seconds since the epoch. Tries GNU date first, then BSD/macOS date.
function _aws_iso_to_epoch() {
  local iso="$1" ts
  if ts="$(date -d "$iso" +%s 2>/dev/null)"; then
    print -r -- "$ts"
    return 0
  fi
  local stripped="${iso%Z}"
  stripped="${stripped%+*}"
  if ts="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)"; then
    print -r -- "$ts"
    return 0
  fi
  return 1
}

# AWS profile switch
function acp() {
  if [[ -z "$1" ]]; then
    unset AWS_DEFAULT_PROFILE AWS_PROFILE AWS_EB_PROFILE
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    unset AWS_CREDENTIAL_EXPIRATION _AWS_CREDENTIAL_EXPIRATION_EPOCH
    echo AWS profile cleared.
    return
  fi

  local -a available_profiles
  available_profiles=($(alp))
  if [[ -z "${available_profiles[(r)$1]}" ]]; then
    echo "${fg[red]}Profile '$1' not found in '${AWS_CONFIG_FILE:-$HOME/.aws/config}'" >&2
    echo "Available profiles: ${(j:, :)available_profiles:-no profiles found}${reset_color}" >&2
    return 1
  fi

  local profile="$1"
  _aws_load_profile "$profile"

  # Get fallback credentials for if the aws command fails or no command is run
  local aws_access_key_id="${_aws_profile_data[aws_access_key_id]}"
  local aws_secret_access_key="${_aws_profile_data[aws_secret_access_key]}"
  local aws_session_token="${_aws_profile_data[aws_session_token]}"

  # SSO short-circuit: if the profile is an SSO profile, run `aws sso login`
  # (which handles the browser dance + caches a bearer token under
  # ~/.aws/sso/cache/) and then materialize the resulting credentials via
  # `aws configure export-credentials` so tools that don't speak SSO still
  # work. Falls back to setting only AWS_PROFILE when export-credentials
  # isn't available (CLI < 2.13).
  local sso_session="${_aws_profile_data[sso_session]}"
  local sso_start_url="${_aws_profile_data[sso_start_url]}"
  if [[ -n "$sso_session" || -n "$sso_start_url" ]]; then
    echo "SSO profile detected; running 'aws sso login --profile $profile'"
    if ! aws sso login --profile "$profile"; then
      echo "${fg[red]}aws sso login failed${reset_color}" >&2
      return 1
    fi
    local sso_creds
    if sso_creds="$(aws configure export-credentials --profile "$profile" --format env-no-export 2>/dev/null)"; then
      # export-credentials prints lines like AWS_ACCESS_KEY_ID=...; eval is
      # safe here because the source is the AWS CLI we just invoked. It also
      # sets AWS_CREDENTIAL_EXPIRATION which we mirror to an epoch sidecar.
      eval "$sso_creds"
      export AWS_DEFAULT_PROFILE="$profile" AWS_PROFILE="$profile" AWS_EB_PROFILE="$profile"
      if [[ -n "$AWS_CREDENTIAL_EXPIRATION" ]]; then
        local epoch
        if epoch="$(_aws_iso_to_epoch "$AWS_CREDENTIAL_EXPIRATION")"; then
          export _AWS_CREDENTIAL_EXPIRATION_EPOCH="$epoch"
        fi
      fi
      echo "Switched to AWS Profile: $profile (SSO)"
    else
      export AWS_DEFAULT_PROFILE="$profile" AWS_PROFILE="$profile" AWS_EB_PROFILE="$profile"
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      unset AWS_CREDENTIAL_EXPIRATION _AWS_CREDENTIAL_EXPIRATION_EPOCH
      echo "Switched to AWS Profile: $profile (SSO; SDK will resolve creds from cache)"
    fi
    return 0
  fi

  # First, if the profile has MFA configured, lets get the token and session duration
  local mfa_serial="${_aws_profile_data[mfa_serial]}"
  local sess_duration="${_aws_profile_data[duration_seconds]}"

  if [[ -n "$mfa_serial" ]]; then
    local -a mfa_opt
    local mfa_token
    # If the profile defines `mfa_command`, run it to obtain the token instead
    # of prompting interactively. Useful for `pass otp`, `ykman oath code`,
    # `op item get`, etc. The command must print the 6-digit token on stdout.
    local mfa_command="${_aws_profile_data[mfa_command]}"
    if [[ -n "$mfa_command" ]]; then
      mfa_token="$(eval "$mfa_command" 2>/dev/null | tr -d '[:space:]')"
      if [[ -z "$mfa_token" ]]; then
        echo "${fg[red]}mfa_command produced no output: $mfa_command${reset_color}" >&2
        return 1
      fi
    else
      echo -n "Please enter your MFA token for $mfa_serial: "
      read -rs mfa_token
      echo
    fi
    if [[ ! "$mfa_token" =~ ^[0-9]{6}$ ]]; then
      echo "${fg[red]}Invalid MFA token: expected 6 digits${reset_color}" >&2
      return 1
    fi
    if [[ -z "$sess_duration" ]]; then
      echo -n "Please enter the session duration in seconds (900-43200; default: 3600, which is the default maximum for a role): "
      read -r sess_duration
    fi
    sess_duration="${sess_duration:-3600}"
    if [[ ! "$sess_duration" =~ ^[0-9]+$ ]] || (( sess_duration < 900 || sess_duration > 43200 )); then
      echo "${fg[red]}Invalid session duration: must be an integer in 900..43200${reset_color}" >&2
      return 1
    fi
    mfa_opt=(--serial-number "$mfa_serial" --token-code "$mfa_token" --duration-seconds "$sess_duration")
  fi

  # Now see whether we need to just MFA for the current role, or assume a different one
  local role_arn="${_aws_profile_data[role_arn]}"
  local sess_name="${_aws_profile_data[role_session_name]}"

  local -a aws_command
  if [[ -n "$role_arn" ]]; then
    # Means we need to assume a specified role
    aws_command=(aws sts assume-role --role-arn "$role_arn" "${mfa_opt[@]}")

    # Check whether external_id is configured to use while assuming the role
    local external_id="${_aws_profile_data[external_id]}"
    if [[ -n "$external_id" ]]; then
      aws_command+=(--external-id "$external_id")
    fi

    # Get source profile to use to assume role; fall back to the role profile
    # itself so the AWS CLI can resolve credentials from credential_process,
    # instance metadata, etc.
    local source_profile="${_aws_profile_data[source_profile]}"
    local credentials_profile="${source_profile:-$profile}"
    if [[ -z "$sess_name" ]]; then
      sess_name="$credentials_profile"
    fi
    aws_command+=(--profile="$credentials_profile" --role-session-name "${sess_name}")

    echo "Assuming role $role_arn using profile $credentials_profile"
  else
    # Means we only need to do MFA
    aws_command=(aws sts get-session-token --profile="$profile" "${mfa_opt[@]}")
    echo "Obtaining session token for profile $profile"
  fi

  # Format output of aws command for easier processing
  aws_command+=(--query '[Credentials.AccessKeyId,Credentials.SecretAccessKey,Credentials.SessionToken,Credentials.Expiration]' --output text)

  # Run the aws command to obtain credentials
  local -a credentials
  credentials=(${(ps:\t:)"$(${aws_command[@]})"})

  local credential_expiration=""
  if [[ -n "$credentials" ]]; then
    aws_access_key_id="${credentials[1]}"
    aws_secret_access_key="${credentials[2]}"
    aws_session_token="${credentials[3]}"
    credential_expiration="${credentials[4]}"
  fi

  # Switch to AWS profile
  if [[ -n "${aws_access_key_id}" && -n "$aws_secret_access_key" ]]; then
    export AWS_DEFAULT_PROFILE="$profile"
    export AWS_PROFILE="$profile"
    export AWS_EB_PROFILE="$profile"
    export AWS_ACCESS_KEY_ID="$aws_access_key_id"
    export AWS_SECRET_ACCESS_KEY="$aws_secret_access_key"

    if [[ -n "$aws_session_token" ]]; then
      export AWS_SESSION_TOKEN="$aws_session_token"
    else
      unset AWS_SESSION_TOKEN
    fi

    if [[ -n "$credential_expiration" && "$credential_expiration" != "None" ]]; then
      export AWS_CREDENTIAL_EXPIRATION="$credential_expiration"
      local epoch
      if epoch="$(_aws_iso_to_epoch "$credential_expiration")"; then
        export _AWS_CREDENTIAL_EXPIRATION_EPOCH="$epoch"
      else
        unset _AWS_CREDENTIAL_EXPIRATION_EPOCH
      fi
    else
      unset AWS_CREDENTIAL_EXPIRATION _AWS_CREDENTIAL_EXPIRATION_EPOCH
    fi

    echo "Switched to AWS Profile: $profile"
  fi
}

function acak() {
  if [[ -z "$1" ]]; then
    echo "usage: $0 <profile>"
    return 1
  fi

  echo "Insert the credentials when asked."
  asp "$1" || return 1
  AWS_PAGER="" aws iam create-access-key
  AWS_PAGER="" aws configure --profile "$1"

  echo "You can now safely delete the old access key running \`aws iam delete-access-key --access-key-id ID\`"
  echo "Your current keys are:"
  AWS_PAGER="" aws iam list-access-keys
}

# Modern completion: _describe shows profile names with their region/role as a
# description column when available. compctl is kept as a fallback for the rare
# case where the new-style completion system isn't initialized.
function _zsh_aws_profile_complete() {
  local -a profiles descriptions
  local p region role desc
  profiles=("${(@f)$(alp 2>/dev/null)}")
  for p in "${profiles[@]}"; do
    [[ -z "$p" ]] && continue
    _aws_load_profile "$p"
    region="${_aws_profile_data[region]}"
    role="${_aws_profile_data[role_arn]}"
    desc=""
    [[ -n "$region" ]] && desc="$region"
    [[ -n "$role" ]] && desc="${desc:+$desc }→ ${role##*/}"
    if [[ -n "$desc" ]]; then
      descriptions+=("$p:$desc")
    else
      descriptions+=("$p")
    fi
  done
  _describe -t aws-profiles 'AWS profile' descriptions
}

function _aws_profiles() {
  reply=($(alp))
}

function _zsh_aws_region_complete() {
  _describe -t aws-regions 'AWS region' _AWS_REGIONS
}

if (( $+functions[compdef] )); then
  compdef _zsh_aws_profile_complete asp acp acak
  compdef _zsh_aws_region_complete asr
else
  compctl -K _aws_profiles asp acp acak
  function _aws_regions() { reply=("${_AWS_REGIONS[@]}") }
  compctl -K _aws_regions asr
fi

# AWS prompt
function aws_prompt_info() {
  [[ -z $AWS_PROFILE ]] && return
  local region="${AWS_REGION:-$AWS_DEFAULT_REGION}"
  local region_segment=""
  if [[ -n "$region" && "$SHOW_AWS_REGION_IN_PROMPT" != false ]]; then
    region_segment="${ZSH_THEME_AWS_REGION_PREFIX:=@}${region}${ZSH_THEME_AWS_REGION_SUFFIX:=}"
  fi
  local ttl_segment=""
  if [[ -n "$_AWS_CREDENTIAL_EXPIRATION_EPOCH" && "$SHOW_AWS_EXPIRY_IN_PROMPT" != false ]]; then
    local remaining=$(( _AWS_CREDENTIAL_EXPIRATION_EPOCH - EPOCHSECONDS ))
    local warn_secs="${ZSH_THEME_AWS_EXPIRY_WARN_SECS:-300}"
    if (( remaining <= 0 )); then
      ttl_segment=" ${ZSH_THEME_AWS_EXPIRY_WARN_COLOR:-${fg[red]}}EXPIRED${reset_color}"
    elif (( remaining < warn_secs )); then
      ttl_segment=" ${ZSH_THEME_AWS_EXPIRY_WARN_COLOR:-${fg[red]}}$((remaining / 60))m${reset_color}"
    else
      ttl_segment=" $((remaining / 60))m"
    fi
  fi
  echo "${ZSH_THEME_AWS_PREFIX:=<aws:}${AWS_PROFILE}${region_segment}${ttl_segment}${ZSH_THEME_AWS_SUFFIX:=>}"
}

if [[ "$SHOW_AWS_PROMPT" != false && "$RPROMPT" != *'$(aws_prompt_info)'* ]]; then
  RPROMPT='$(aws_prompt_info)'"$RPROMPT"
fi


# Load awscli completions

# AWS CLI v2 comes with its own autocompletion. Check if that is there, otherwise fall back
if command -v aws_completer &> /dev/null; then
  complete -C aws_completer aws
else
  # Persist the resolved completer path so we don't repeat the (~400 ms)
  # `brew --prefix awscli` call on every new shell. Cache is invalidated when
  # the cached path no longer exists (e.g. CLI was upgraded or uninstalled).
  _aws_completer_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh-aws"
  _aws_completer_cache_file="$_aws_completer_cache_dir/completer-path"

  _aws_zsh_completer_path=""
  if [[ -r "$_aws_completer_cache_file" ]]; then
    _aws_zsh_completer_path="$(< "$_aws_completer_cache_file")"
    [[ -r "$_aws_zsh_completer_path" ]] || _aws_zsh_completer_path=""
  fi

  if [[ -z "$_aws_zsh_completer_path" ]]; then
    function _awscli-homebrew-installed() {
      # check if Homebrew is installed
      (( $+commands[brew] )) || return 1

      # speculatively check default brew prefix
      if [ -h /usr/local/opt/awscli ]; then
        _brew_prefix=/usr/local/opt/awscli
      else
        # ok, it is not in the default prefix
        # this call to brew is expensive (about 400 ms), so at least let's make it only once
        _brew_prefix=$(brew --prefix awscli 2>/dev/null) || return 1
        [[ -n "$_brew_prefix" ]] || return 1
      fi
    }

    # get aws_zsh_completer.sh location from $PATH
    _aws_zsh_completer_path="$commands[aws_zsh_completer.sh]"

    # otherwise check common locations
    if [[ -z $_aws_zsh_completer_path ]]; then
      # Homebrew
      if _awscli-homebrew-installed; then
        _aws_zsh_completer_path=$_brew_prefix/libexec/bin/aws_zsh_completer.sh
      # Ubuntu
      elif [[ -e /usr/share/zsh/vendor-completions/_awscli ]]; then
        _aws_zsh_completer_path=/usr/share/zsh/vendor-completions/_awscli
      # NixOS
      elif [[ -e "${commands[aws]:P:h:h}/share/zsh/site-functions/aws_zsh_completer.sh" ]]; then
        _aws_zsh_completer_path="${commands[aws]:P:h:h}/share/zsh/site-functions/aws_zsh_completer.sh"
      # RPM
      else
        _aws_zsh_completer_path=/usr/share/zsh/site-functions/aws_zsh_completer.sh
      fi
    fi

    if [[ -r "$_aws_zsh_completer_path" ]]; then
      [[ -d "$_aws_completer_cache_dir" ]] || mkdir -p "$_aws_completer_cache_dir" 2>/dev/null
      print -r -- "$_aws_zsh_completer_path" > "$_aws_completer_cache_file" 2>/dev/null
    fi
    unfunction _awscli-homebrew-installed 2>/dev/null
  fi

  [[ -r $_aws_zsh_completer_path ]] && source $_aws_zsh_completer_path
  unset _aws_zsh_completer_path _brew_prefix _aws_completer_cache_dir _aws_completer_cache_file
fi

