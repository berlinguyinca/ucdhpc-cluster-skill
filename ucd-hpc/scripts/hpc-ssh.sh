#!/usr/bin/env bash
# hpc-ssh.sh — run a command on a UC Davis HPC login node (hive, farm, franklin) with safe,
# consistent defaults. Replaces hand-rolled `timeout N ssh -o BatchMode=... 'bash -lc ...'`,
# the single most common hand-rolled command across Claude/pi/codex sessions on this account.
#
# Why the hand-rolled form fails, and how this avoids it:
#   * QUOTING — `&&`, `|`, `$VAR`, and embedded quotes must reach the cluster intact. This
#     wrapper single-quotes the whole remote command once, correctly, so callers never escape.
#   * CONTROLMASTER — agents passed `-o ControlMaster=no` + a scratchpad ControlPath, which
#     DISABLED the ~/.ssh/config multiplexing (and failed ~40% of the time). This wrapper never
#     touches ControlMaster, so the config's shared socket just works.
#
# Design: the cluster target is passed to `ssh` AS TYPED. Your ~/.ssh/config supplies the
# HostName and User (e.g. `Host hive { HostName hive.hpc.ucdavis.edu, User gw }`) plus the
# connect/keepalive/multiplex settings. This wrapper adds only what a bare `ssh` lacks for HPC:
# a `bash -lc` login-shell wrap (so `module` and the Slurm path work), correct quoting,
# fail-fast BatchMode, and an optional overall timeout.
#
# Exit status is that of the remote command, so agents can rely on it.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML="$SELF_DIR/../clusters.yml"
CONNECT=""        # empty = inherit the ssh config's ConnectTimeout
TIMEOUT=0
INTERACTIVE=0
NO_MULTIPLEX=0
RAW=0
USER_OVERRIDE=""
EXEC_FILE=""
DRY=0
VERBOSE=0
EXTRA_OPTS=()

usage() {
  cat <<'EOF'
hpc-ssh.sh — run a command on a UC Davis HPC login node (hive, farm, franklin).

  hpc-ssh.sh <cluster> -- <cmd...>   run a command (wrapped in a login shell)
  hpc-ssh.sh <cluster> --exec FILE   run a local script FILE on the login node (via stdin)
  hpc-ssh.sh                         list the known clusters

The host and user come from your ~/.ssh/config (e.g. 'Host hive' -> User gw); the cluster name
is passed through so those settings apply. Put `--` before the command so its own flags are
not read as options.

Options (may appear before or after the cluster name; put `--` before the command):
  -t, --timeout SECS   cap the whole call at SECS (default: off)
      --connect SECS   set ConnectTimeout (default: inherit your ssh config)
  -i, --interactive    allow passphrase/yes-no prompts (default: fail fast, no prompt)
      --no-multiplex   pass ControlMaster=no (disable the shared control socket)
      --raw            skip the bash -lc login-shell wrap (remote default shell runs it)
  -u, --user USER      remote user (overrides user@target and the ssh config)
  -o, --opt OPT        extra ssh -o OPT (repeatable)
  -v, --verbose        print the resolved ssh command
      --dry-run        print the resolved command and do not run it
  -h, --help           this help
EOF
}
die() { echo "hpc-ssh: $*" >&2; exit "${2:-1}"; }

# Single-quote a string so it survives one round of remote-shell parsing as ONE word:
# each embedded ' becomes '\''.
remote_quote() {
  local s=$1
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

if [ $# -eq 0 ]; then
  usage
  echo
  echo "Known clusters (from clusters.yml):"
  awk '/^  - name: /{print "  " $3}' "$YAML" 2>/dev/null || echo "  (clusters.yml not found next to scripts/)"
  exit 0
fi

# --- parse arguments -----------------------------------------------------------
# Everything after the first `--` is the remote command, passed verbatim (its `-u`, `-o`,
# `&&`, `|`, `$VAR` are NOT read as options). Before the `--` (or, without one, after the
# target) we find the target and the script options, which may appear before OR after it.
front=(); remote=(); saw_sep=0
for a in "$@"; do
  if [ "$a" = "--" ] && [ $saw_sep -eq 0 ]; then saw_sep=1; continue; fi
  if [ $saw_sep -eq 1 ]; then remote+=("$a"); else front+=("$a"); fi
done

TARGET=""
i=0; n=${#front[@]}
if [ $saw_sep -eq 1 ]; then
  # `--` present: scan all of front; options anywhere, first bare token = target.
  while [ $i -lt $n ]; do
    a=${front[i]}
    case "$a" in
      -h|--help) usage; exit 0 ;;
      --dry-run) DRY=1 ;;
      -v|--verbose) VERBOSE=1 ;;
      --raw) RAW=1 ;;
      -i|--interactive) INTERACTIVE=1 ;;
      --no-multiplex) NO_MULTIPLEX=1 ;;
      -t|--timeout) i=$((i+1)); TIMEOUT=${front[i]:?missing SECS after $a} ;;
      --connect) i=$((i+1)); CONNECT=${front[i]:?missing SECS after $a} ;;
      --exec)    i=$((i+1)); EXEC_FILE=${front[i]:?missing FILE after $a} ;;
      -o)        i=$((i+1)); EXTRA_OPTS+=("${front[i]:?missing OPT after $a}") ;;
      -u)        i=$((i+1)); USER_OVERRIDE=${front[i]:?missing USER after $a} ;;
      -*) die "unknown option: $a (see --help)" 2 ;;
      *) [ -z "$TARGET" ] && TARGET="$a" ;;
    esac
    i=$((i+1))
  done
else
  # no `--`: options only up to the first bare token (= target); the rest is the remote cmd.
  while [ $i -lt $n ]; do
    a=${front[i]}
    case "$a" in
      -h|--help) usage; exit 0 ;;
      --dry-run) DRY=1 ;;
      -v|--verbose) VERBOSE=1 ;;
      --raw) RAW=1 ;;
      -i|--interactive) INTERACTIVE=1 ;;
      --no-multiplex) NO_MULTIPLEX=1 ;;
      -t|--timeout) i=$((i+1)); TIMEOUT=${front[i]:?missing SECS after $a} ;;
      --connect) i=$((i+1)); CONNECT=${front[i]:?missing SECS after $a} ;;
      --exec)    i=$((i+1)); EXEC_FILE=${front[i]:?missing FILE after $a} ;;
      -o) i=$((i+1)); EXTRA_OPTS+=("${front[i]:?missing OPT after $a}") ;;
      -u) i=$((i+1)); USER_OVERRIDE=${front[i]:?missing USER after $a} ;;
      -*) die "unknown option: $a (see --help)" 2 ;;
      *) break ;;
    esac
    i=$((i+1))
  done
  [ $i -lt $n ] || { usage >&2; exit 2; }
  TARGET=${front[i]}; i=$((i+1))
  if [ $i -lt $n ]; then remote=("${front[@]:i}"); else remote=(); fi
fi
[ -n "$TARGET" ] || { usage >&2; exit 2; }

# --- remote command ------------------------------------------------------------
if [ -n "$EXEC_FILE" ]; then
  REMOTE=()
else
  REMOTE=("${remote[@]+"${remote[@]}"}")
  [ ${#REMOTE[@]} -gt 0 ] || die "no remote command (usage: hpc-ssh.sh <cluster> -- <cmd>, or --exec FILE)" 2
fi

# --- user (target may carry user@) ---------------------------------------------
user="$USER_OVERRIDE"
case "$TARGET" in *@*) user="${user:-${TARGET%%@*}}"; TARGET="${TARGET##*@}";; esac

# Friendly (non-fatal) hint if the target is not a known cluster name and not an obvious host.
if [ -f "$YAML" ]; then
  if ! awk -v q="$TARGET" '$0 ~ ("^  - name: " q "$"){f=1} END{exit f?0:1}' "$YAML" 2>/dev/null; then
    case "$TARGET" in
      *.*) : ;;
      *) echo "hpc-ssh: note: '$TARGET' is not in clusters.yml; ssh passes it to your config (known: $(awk '/^  - name:/{printf "%s ",$3}' "$YAML"))." >&2 ;;
    esac
  fi
fi

# --- build ssh options (thin: respect the ssh config) --------------------------
ssh_opts=()
[ "$INTERACTIVE" -eq 0 ] && ssh_opts+=(-o BatchMode=yes)
[ -n "$CONNECT" ] && ssh_opts+=(-o "ConnectTimeout=$CONNECT")
[ "$NO_MULTIPLEX" -eq 1 ] && ssh_opts+=(-o ControlMaster=no -o ControlPath=none)
[ -n "$user" ] && ssh_opts+=(-l "$user")
for o in ${EXTRA_OPTS[@]+"${EXTRA_OPTS[@]}"}; do ssh_opts+=(-o "$o"); done

# --- build the remote command (sent to the cluster as ONE argument) ------------
if [ -n "$EXEC_FILE" ]; then
  [ -r "$EXEC_FILE" ] || die "cannot read --exec file: $EXEC_FILE" 2
  remote_arg="bash -ls"
  STDIN="$EXEC_FILE"
else
  remote_cmd="${REMOTE[*]}"
  if [ "$RAW" -eq 1 ]; then
    remote_arg="$(remote_quote "$remote_cmd")"
  else
    remote_arg="bash -lc $(remote_quote "$remote_cmd")"
  fi
  STDIN=""
fi

run_prefix=(ssh)
[ "$TIMEOUT" -gt 0 ] && run_prefix=(timeout "$TIMEOUT" ssh)
cmd=("${run_prefix[@]}" "${ssh_opts[@]}" "$TARGET" "$remote_arg")

if [ "$VERBOSE" -eq 1 ] || [ "$DRY" -eq 1 ]; then
  if [ -n "$STDIN" ]; then
    echo "+ stdin< $STDIN   ${cmd[*]}" >&2
  else
    echo "+ ${cmd[*]}" >&2
  fi
fi
[ "$DRY" -eq 1 ] && exit 0

if [ -n "$STDIN" ]; then
  "${cmd[@]}" < "$STDIN"
else
  "${cmd[@]}"
fi
exit $?
