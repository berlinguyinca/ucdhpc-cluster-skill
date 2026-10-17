# ucd-hpc — an agent skill for UC Davis HPC users

A skill (Agent Skills spec) that teaches an AI coding agent how the UC Davis HPC@UCD clusters
(**Farm**, **Franklin**, **Hive**) actually work: which partitions and accounts a user has, the
free-tier limits, how to request CPUs/memory/GPUs/time, why jobs fail or sit pending, where
software lives (modules, conda, Apptainer, Open OnDemand), and how storage and data transfer work.

The skill is harness-neutral — it works in Claude Code, pi, opencode, and OpenAI Codex (each
reads the same Agent Skills spec — a directory containing `SKILL.md` — from its own skill
directory). It is `ucd-hpc/` and bundles:

- `SKILL.md` — the workflow the agent follows (identify cluster → probe live → read references → verify).
- `clusters.yml` — the single source of truth for per-cluster facts (partitions, limits, GPUs,
  storage, software). Add a cluster by adding a block here; nothing else needs to change.
- `references/` — distilled, verified facts: shared Slurm behavior, debugging tables, software,
  storage, and one narrative file per cluster (`hive.md`, `farm.md`, `franklin.md`). The tabular
  facts in each defer to `clusters.yml`.
- `scripts/show-cluster.sh [CLUSTER]` — renders a cluster's `clusters.yml` block (resolves a name,
  login host, or alias); no argument lists the clusters.
- `scripts/cluster-context.sh` — read-only snapshot of the user's accounts, QOS limits, partitions,
  GPUs, storage, and software trees.
- `scripts/job-postmortem.sh JOBID` — explains a pending/failed job from `sacct`/`scontrol` and its logs.
- `scripts/lint-jobscript.sh SCRIPT` — catches cluster-specific mistakes and runs `sbatch --test-only`.

## Install

Clone once, then symlink (or copy) `ucd-hpc/` into the skill directory of the harness you use.

```bash
git clone https://github.com/berlinguyinca/ucdhpc-cluster-skill ~/ucdhpc-cluster-skill
cd ~/ucdhpc-cluster-skill

# Claude Code
mkdir -p ~/.claude/skills
ln -s "$PWD/ucd-hpc" ~/.claude/skills/ucd-hpc

# pi
mkdir -p ~/.agents/skills
ln -s "$PWD/ucd-hpc" ~/.agents/skills/ucd-hpc

# opencode (global skills dir)
mkdir -p ~/.config/opencode/skill
ln -s "$PWD/ucd-hpc" ~/.config/opencode/skill/ucd-hpc

# OpenAI Codex
mkdir -p ~/.codex/skills
ln -s "$PWD/ucd-hpc" ~/.codex/skills/ucd-hpc
```

After installing, run `/reload` in an active pi session (or restart opencode) so the harness
re-scans and advertises the skill. Works best when the agent runs on a cluster login node (live
probes), but the references also let it help from a laptop.

## Sources

Prose is derived from <https://docs.hpc.ucdavis.edu> (source: <https://github.com/ucdavis/hpccf-docs>);
partition, QOS, GPU, and storage facts were verified against the live clusters in September 2026.
Re-verify after maintenance windows: `sinfo -s`, `scontrol show partition`, `sacctmgr show qos`.

## Development

`ucd-hpc/evals/evals.json` holds test prompts. Iteration outputs go to `ucd-hpc-workspace/`
(git-ignored).
