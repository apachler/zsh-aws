#!/usr/bin/env zsh
# Standarized $0 handling, following:
# https://github.com/zdharma/Zsh-100-Commits-Club/blob/master/Zsh-Plugin-Standard.adoc
0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"

if [[ $PMSPEC != *b* ]] {
  PATH=$PATH:"${0:h}/bin"
}


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

# AWS profile selection
function asp() {
  if [[ -z "$1" ]]; then
    unset AWS_DEFAULT_PROFILE AWS_PROFILE AWS_EB_PROFILE
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

# AWS profile switch
function acp() {
  if [[ -z "$1" ]]; then
    unset AWS_DEFAULT_PROFILE AWS_PROFILE AWS_EB_PROFILE
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
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

  # First, if the profile has MFA configured, lets get the token and session duration
  local mfa_serial="${_aws_profile_data[mfa_serial]}"
  local sess_duration="${_aws_profile_data[duration_seconds]}"

  if [[ -n "$mfa_serial" ]]; then
    local -a mfa_opt
    local mfa_token
    echo -n "Please enter your MFA token for $mfa_serial: "
    read -rs mfa_token
    echo
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
  aws_command+=(--query '[Credentials.AccessKeyId,Credentials.SecretAccessKey,Credentials.SessionToken]' --output text)

  # Run the aws command to obtain credentials
  local -a credentials
  credentials=(${(ps:\t:)"$(${aws_command[@]})"})

  if [[ -n "$credentials" ]]; then
    aws_access_key_id="${credentials[1]}"
    aws_secret_access_key="${credentials[2]}"
    aws_session_token="${credentials[3]}"
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

function _aws_profiles() {
  reply=($(alp))
}
compctl -K _aws_profiles asp acp acak

# AWS prompt
function aws_prompt_info() {
  [[ -z $AWS_PROFILE ]] && return
  echo "${ZSH_THEME_AWS_PREFIX:=<aws:}${AWS_PROFILE}${ZSH_THEME_AWS_SUFFIX:=>}"
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

