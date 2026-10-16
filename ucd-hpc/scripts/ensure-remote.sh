#!/usr/bin/env bash
# ensure-remote.sh — install or update the ucd-hpc skill on a SLURM cluster host.
#
# This script is the "automatic install" mechanism for the ucd-hpc skill. It is
# self-contained so it can be piped over ssh. It only clones the repo, symlinks
# the skill into the harness skill directories, and makes the helper scripts
# executable. It never touches the scheduler.
#
# Usage:
#   ensure-remote.sh                # install on the current host (e.g. a login node)
#   ensure-remote.sh <ssh-host>     # install on a remote host reached via ssh
#
# Env:
#   UCDHPC_SKILL_REPO  override the git URL (default: the GitHub repo).
#
# Examples:
#   # Running pi directly ON a cluster login node where the skill is missing:
#   bash ~/.ucdhpc-cluster-skill/ucd-hpc/scripts/ensure-remote.sh
#
#   # Running pi on a laptop, reaching the cluster over ssh:
#   ./scripts/ensure-remote.sh hive
#
set -euo pipefail

REPO="${UCDHPC_SKILL_REPO:-https://github.com/berlinguyinca/ucdhpc-cluster-skill}"

install_on_host() {
  local clone_dir="$HOME/.ucdhpc-cluster-skill"
  local src

  mkdir -p "$HOME/.agents/skills" "$HOME/.config/opencode/skill"

  # Clone once if not present.
  if [ ! -d "$clone_dir/.git" ]; then
    echo "[ensure-remote] cloning $REPO -> $clone_dir"
    git clone --depth 1 "$REPO" "$clone_dir"
  fi

  # Keep an existing clone reasonably fresh (best-effort; a shallow clone is fine).
  ( cd "$clone_dir" && git fetch --depth 1 -q origin 2>/dev/null \
      && git reset --hard -q origin/HEAD 2>/dev/null ) || true

  src="$clone_dir/ucd-hpc"
  if [ ! -f "$src/SKILL.md" ]; then
    echo "[ensure-remote] WARNING: $src/SKILL.md missing; clone may be stale." >&2
  fi

  ln -sfn "$src" "$HOME/.agents/skills/ucd-hpc"
  ln -sfn "$src" "$HOME/.config/opencode/skill/ucd-hpc"
  chmod +x "$src"/scripts/*.sh 2>/dev/null || true

  echo "[ensure-remote] ucd-hpc skill ensured on $(hostname 2>/dev/null || echo localhost):"
  echo "  $HOME/.agents/skills/ucd-hpc          -> $src"
  echo "  $HOME/.config/opencode/skill/ucd-hpc  -> $src"
}

if [ "$#" -gt 0 ]; then
  HOST="$1"
  # Re-invoke this same (self-contained) script on the remote host.
  echo "[ensure-remote] installing on remote host '$HOST'"
  ssh -o BatchMode=yes "$HOST" 'bash -s' < "$0"
else
  install_on_host
fi
