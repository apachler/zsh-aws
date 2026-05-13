#!/usr/bin/env zsh
# Line coverage for zsh-aws.plugin.zsh.
#
# Strategy: install a DEBUG trap before running the test suite. Inside the
# trap, every executed command in a function exposes
# ${funcsourcetrace[1]}="<file>:<def_line>", and $LINENO is the body-relative
# line. So absolute_line = def_line + LINENO. We filter to commands whose
# defining file is zsh-aws.plugin.zsh and write the absolute line numbers to
# a tmp file. Coverage is hits / executable lines, where "executable" means
# any non-blank, non-comment line in the plugin file.
#
# Lines outside any function (PATH setup, zmodload, the typeset -gra region
# array, compdef wiring, RPROMPT injection, completer resolution) execute
# only during sourcing — they don't fire the DEBUG trap with a useful
# funcsourcetrace entry. We capture them with a separate sourcing-pass trap
# that records absolute $LINENO when there's no function context. To avoid
# the readonly _AWS_REGIONS array, the sourcing pass runs in a subshell.
#
# Run with:
#
#   zsh test/coverage.zsh
#   COVERAGE_THRESHOLD=70 zsh test/coverage.zsh
#   COVERAGE_VERBOSE=1 zsh test/coverage.zsh   # list uncovered lines

emulate -L zsh
setopt extended_glob

local REPO="${0:A:h:h}"
local PLUGIN="$REPO/zsh-aws.plugin.zsh"
local PLUGIN_BASENAME="${PLUGIN:t}"
local TEST_RUNNER="$REPO/test/run-tests.zsh"
local THRESHOLD="${COVERAGE_THRESHOLD:-80}"
local HITS_FILE
HITS_FILE=$(mktemp)
trap "rm -f $HITS_FILE" EXIT

[[ -r "$PLUGIN" ]]       || { print -u2 "coverage: cannot read $PLUGIN"; exit 2 }
[[ -r "$TEST_RUNNER" ]]  || { print -u2 "coverage: cannot read $TEST_RUNNER"; exit 2 }

# Run the test suite inside a subshell with a DEBUG trap. The subshell isolates
# the readonly globals (_AWS_REGIONS) and the test runner's exit-at-end.
(
  export SHOW_AWS_PROMPT=false
  export HITS_FILE PLUGIN_BASENAME
  # Function-body lines: funcsourcetrace[1] is "<file>:<def_line>", LINENO is
  # body-relative. Absolute = def_line + LINENO.
  trap '
    if [[ -n "${funcsourcetrace[1]:-}" ]]; then
      local _f="${funcsourcetrace[1]%:*}"
      if [[ "${_f:t}" == "$PLUGIN_BASENAME" ]]; then
        print -- $(( ${funcsourcetrace[1]##*:} + LINENO )) >> "$HITS_FILE"
      fi
    fi
  ' DEBUG
  source "$TEST_RUNNER" >/dev/null 2>&1
)
local suite_rc=$?

# Sourcing pass: capture top-level lines (no function context). In a separate
# subshell so the readonly assignments don't conflict with anything else.
(
  export SHOW_AWS_PROMPT=false
  export HITS_FILE
  trap '
    if [[ -z "${funcsourcetrace[1]:-}" && "${(%):-%N}" != "" ]]; then
      print -- $LINENO >> "$HITS_FILE"
    fi
  ' DEBUG
  source "$PLUGIN" >/dev/null 2>&1
)

# Build the set of executable lines in the plugin. "Executable" excludes:
#   - blank lines and comment-only lines
#   - pure structural tokens (`}`, `fi`, `done`, `else`, `then`, `do`, `;;`)
#     because zsh's DEBUG trap fires for commands, not for syntactic markers
#   - lines inside a parenthesised array/list literal (where every line is
#     just a continuation of a single `typeset`/`local` command that traces
#     at the opening line only)
typeset -gA executable
local lineno=0 line stripped in_array_lit=0 paren_depth=0
local c i
while IFS= read -r line; do
  (( ++lineno ))
  stripped="${line##[[:space:]]##}"
  stripped="${stripped%%[[:space:]]##}"
  [[ -z "$stripped" ]]      && continue
  [[ "$stripped" == '#'* ]] && continue
  # Inside an array literal: count parens until we close, then exit the
  # block. This must run before the structural-token exclusion because
  # the closing `)` of the literal would otherwise be filtered away and
  # the depth counter would never reset.
  if (( in_array_lit )); then
    for (( i=1; i<=${#stripped}; i++ )); do
      c="${stripped[$i]}"
      [[ "$c" == '(' ]] && (( ++paren_depth ))
      [[ "$c" == ')' ]] && (( --paren_depth ))
    done
    if (( paren_depth <= 0 )); then
      in_array_lit=0
      paren_depth=0
    fi
    continue
  fi
  case "$stripped" in
    '}'|fi|done|else|then|do|';;'|')') continue ;;
    'done '*|'done<'*) continue ;;   # done with redirection
  esac
  # Detect start of an array literal opened with `(` at end of line.
  if [[ "$stripped" == *'=('* && "$stripped" != *')'* ]]; then
    executable[$lineno]=1
    in_array_lit=1
    paren_depth=1
    continue
  fi
  executable[$lineno]=1
done < "$PLUGIN"

# Collect unique hits that map to executable lines.
typeset -gA hits
local h
while read -r h; do
  [[ -n "${executable[$h]:-}" ]] && hits[$h]=1
done < "$HITS_FILE"

local total=${#executable}
local hit=${#hits}
local pct
if (( total == 0 )); then
  print -u2 "coverage: no executable lines found in $PLUGIN"
  exit 2
fi
pct=$(awk -v h=$hit -v t=$total 'BEGIN { printf "%.1f", (h/t)*100 }')

print ""
print "===== Coverage ====="
print "Plugin file:      $PLUGIN_BASENAME"
print "Lines executed:   $hit / $total"
print "Line coverage:    $pct%"
print "Threshold:        $THRESHOLD%"

if [[ -n "${COVERAGE_VERBOSE:-}" ]]; then
  print ""
  print "Uncovered lines:"
  local n
  for n in ${(on)${(k)executable}}; do
    if [[ -z "${hits[$n]:-}" ]]; then
      printf "  %4d: %s\n" "$n" "$(sed -n "${n}p" "$PLUGIN")"
    fi
  done
fi

if (( suite_rc != 0 )); then
  print -u2 ""
  print -u2 "Test suite exited non-zero ($suite_rc)."
  exit $suite_rc
fi

if awk "BEGIN { exit !($pct >= $THRESHOLD) }"; then
  exit 0
else
  print -u2 ""
  print -u2 "Coverage $pct% is below threshold $THRESHOLD%."
  exit 1
fi
