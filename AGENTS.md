# Agent Colonies

Agent Colonies is a stigmergy-inspired agent loop system. It takes a high-level goal and uses autonomous AI agents to collaboratively build software through decentralized coordination.

## Repository Overview

This repo contains the **shared tooling** — scripts, prompts, and skills — that drive the colony loop. It is cloned once and used across multiple projects. Per-project data lives in `agent-colony/` inside each target project (created by `setup.sh`).

### Key Files

| File | Purpose |
|------|---------|
| `colony-build.sh` | Main loop — dispatches agents in rotating roles (implementer, reviewer, simplifier, validator) |
| `plan.sh` | Plan management CLI — agents use this to read/update `plan.json` (jq wrapper) |
| `setup.sh` | Initializes `agent-colony/` directory in a target project |
| `install.sh` | One-time global install — symlinks skills, stores source path |
| `prompts/implementer.md` | Implementer prompt — gap analysis, TDD, implement, self-review |
| `prompts/reviewer.md` | Reviewer prompt — code quality, plan coherence, advisory nudges |
| `prompts/simplifier.md` | Simplifier prompt — three-lens review (reuse, quality, efficiency), refactor |
| `prompts/validator.md` | Validator prompt — e2e tests, feature completeness verification |
| `skills/colony-bootstrap/SKILL.md` | Claude Code skill for `/colony-bootstrap` command |

### Docs

| File | Purpose |
|------|---------|
| `docs/agent-colonies-design.md` | Full design document with rationale and tradeoffs |
| `docs/cli-reference.md` | `plan.sh` command reference for agents |
| `docs/plan-schema.md` | `plan.json` schema with field descriptions |

### Examples

| File | Purpose |
|------|---------|
| `goal.md.example` | Example goal document (task priority system) |
| `plan.json.example` | Example plan with tasks, votes, comments, subtasks |

## How the System Works

### The Loop (`colony-build.sh`)

1. Reads `plan.json` and the goal document from the target project's `agent-colony/` directory
2. Determines the role for this iteration (implementer > reviewer > simplifier, based on iteration number)
3. Builds a prompt from `prompts/<role>.md` + runtime context (file paths, iteration number)
4. Dispatches the prompt to the selected agent CLI (Codex or Claude Code)
5. Logs the iteration in `plan.json` metadata
6. Repeats until validator confirms completion or max iterations reached

### Role Dispatch

- Implementer: all iterations not claimed by reviewer or simplifier
- Reviewer: every `--review-every N` iterations (default 3)
- Simplifier: every `--simplify-every M` iterations (default 7)
- Validator: automatically triggered when all tasks are "done"
- If both reviewer and simplifier are due, reviewer wins (quality first)

### Plan Management (`plan.sh`)

Agents interact with `plan.json` through `plan.sh` commands:
- `summary` — all tasks with statuses, vote counts, subtask progress
- `show <id>` — full detail on one task
- `create`, `update`, `claim`, `vote`, `comment` — mutations
- `subtask add/done/update/remove` — subtask management
- `split` — break large tasks into smaller ones
- `stats` — overall plan statistics

Environment variables `COLONY_PLAN_FILE`, `COLONY_ITERATION`, and `COLONY_ROLE` are set by `colony-build.sh`.

### Per-Project Structure

When a colony runs on a project, it creates:
```
target-project/
└── agent-colony/
    ├── plan.json       # The living plan (tasks, votes, comments)
    ├── progress.txt    # Agent progress log with learnings
    ├── .last-branch    # Branch tracking for archiving
    └── archive/        # Previous runs (auto-archived on branch change)
```

## Development Guidelines

### Modifying Prompts

Each prompt in `prompts/` follows the same structure:
1. Runtime context block (`[COLONY RUNTIME]`) — injected by `colony-build.sh`
2. Role-specific workflow — phased instructions
3. Principles — decision-making guidance

When editing prompts:
- Keep the `[COLONY RUNTIME]` reference — agents need it for file paths
- Reference `./plan.sh` commands — the runtime note at the top maps them to the actual path
- Test with both `--agent codex` and `--agent claude` — behavior may differ

### Modifying plan.sh

All commands are `jq` operations on `plan.json`. Key conventions:
- Use `tmp_update()` for atomic writes (write to `.tmp`, then `mv`)
- Use `next_id()` for sequential task IDs
- Environment variables provide iteration context

### Modifying colony-build.sh

The main loop handles:
- Argument parsing and validation
- Branch archiving (when `agent-colony/.last-branch` differs from current branch)
- Role dispatch (`get_role()` function)
- Prompt building (`build_prompt()` function)
- Agent dispatch (`dispatch_agent()` function) — currently uses the same invocation for all roles (no read-only sandbox for reviewer, despite the design doc suggesting it)
- Iteration logging to `plan.json` metadata
- Completion detection (validator + no new tasks)
- Consecutive validation safety (forces implementer after 3 consecutive validator runs)

### Testing Changes

There is no automated test suite for the tooling itself. To test:
1. Run `setup.sh` on a test project — verify `agent-colony/` is created correctly
2. Run `plan.sh` commands manually — verify JSON mutations are correct
3. Run `colony-build.sh` with `--agent claude 1` or `--agent codex 1` for a single iteration

## Prerequisites

- `jq` — required (plan management)
- `claude` CLI — for `--agent claude` mode
- `codex` CLI — for `--agent codex` mode (default)

## Quick Start for Contributors

```bash
# Clone and install
git clone https://github.com/tejasdc/agent-colonies.git
cd agent-colonies
./install.sh

# Test on a project
cd /path/to/your-project
/colony-bootstrap                    # In Claude Code
colony-build.sh --agent claude 3     # Run 3 iterations with Claude
```
