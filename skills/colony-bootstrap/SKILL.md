---
name: colony-bootstrap
description: Bootstrap, run, and monitor Agent Colonies. Use when starting a new colony, checking colony status, or managing a running colony.
---

# Agent Colony Management

This skill covers the full colony lifecycle: bootstrap, run, monitor, and manage.

## Bootstrap a New Colony

### Step 1: Find Source Directory & Run Setup

Find the agent-colonies source directory:

```bash
cat ~/.config/agent-colonies/source-dir
```

This file contains the absolute path to the agent-colonies source (e.g., `/Users/alice/workspace/agent-colonies`). If the file doesn't exist, the user hasn't run `install.sh` yet — tell them to run it first from wherever they cloned the repo.

Store it for later use:

```bash
COLONY_SRC=$(cat ~/.config/agent-colonies/source-dir)
```

Then run the setup script:

```bash
$COLONY_SRC/setup.sh
```

This deterministically:
- Creates `agent-colony/` directory
- Initializes `progress.txt` and `patterns.txt`
- Archives any previous run if the branch changed
- Checks tool availability (claude, codex, jq)

### Step 2: Find the Goal Document

Look for a goal or design document in the current project. Check these locations in order:

1. An existing `agent-colony/plan.json` — if it has a `goalFile` field, use that
2. Files in `docs/` matching common patterns: `*design*.md`, `*goal*.md`, `*spec*.md`
3. Root-level files: `goal.md`, `GOAL.md`, `design.md`, `spec.md`
4. Any `.md` file the user recently created or discussed in conversation

If multiple candidates exist, ask the user which one to use. If none exist, tell the user they need a goal document first and offer to help write one.

### Step 3: Read the Goal

Read the document. It could be:
- A short goal statement (paragraph)
- A structured goal with outcomes and non-goals
- A full design document with implementation plan

### Step 4: Analyze the Codebase

Before creating tasks, understand what already exists:

1. Read the project structure (key directories and files)
2. Check for existing test infrastructure
3. Look at package.json / Makefile / build config to understand the tech stack
4. Identify what's already built vs what needs to be built
5. Determine the project name from package.json, directory name, or context
6. Check the current git branch — use it as the colony branch, or suggest `colony/<feature-name>`

### Step 5: Break Down Into Tasks

Create tasks that cover the gap between current state and the goal:

**Rules for task creation:**
- Each task should be roughly user-story sized (completable in one agent iteration)
- Tasks should be independent where possible (minimize dependencies)
- Include 2-4 subtasks per task as implementation guidance
- Don't create tasks for things that already exist in the codebase
- Don't over-specify — leave room for agents to discover details during implementation
- Order tasks roughly by dependency (foundations first, UI/integration last)

**What to include:**
- Data model / schema changes (if needed)
- Core logic / business rules
- API endpoints or service layer
- UI components and integration
- Wiring / integration between pieces

**What NOT to include:**
- Testing tasks (agents write tests as part of TDD workflow)
- Review or cleanup tasks (reviewer and simplifier roles handle this)
- Tasks that are too small (single function/line changes)
- Tasks that duplicate what already exists

### Step 6: Create plan.json

Write `agent-colony/plan.json` with this structure:

```json
{
  "project": "<project-name>",
  "branchName": "<branch-name>",
  "goalFile": "<relative-path-to-goal-document>",
  "tasks": [
    {
      "id": "T-001",
      "title": "Short imperative description",
      "description": "Detailed description of what needs to happen and why.",
      "subtasks": [
        { "description": "Step 1", "done": false },
        { "description": "Step 2", "done": false }
      ],
      "votes": [],
      "comments": [],
      "status": "open",
      "createdBy": { "iteration": 0, "role": "bootstrap" },
      "claimedBy": null,
      "splitFrom": null
    }
  ],
  "metadata": {
    "createdAt": "<ISO-8601-timestamp>",
    "totalIterations": 0,
    "iterationLog": []
  }
}
```

**Task ID format:** Sequential T-001, T-002, T-003, etc.

**createdBy:** Use `{ "iteration": 0, "role": "bootstrap" }` to distinguish bootstrapped tasks from agent-created tasks.

### Step 7: Verify & Report

1. Validate the JSON: `jq '.' agent-colony/plan.json`
2. Print a summary:

```
Colony bootstrapped:
  Project: <name>
  Branch: <branch>
  Goal: <goal-file>
  Tasks: <count>

Tasks created:
  T-001: <title>
  T-002: <title>
  ...

Next steps:
  Start the colony:  $COLONY_SRC/colony-build.sh 250
  Check health:      COLONY_PLAN_FILE=agent-colony/plan.json $COLONY_SRC/plan.sh health
  Task summary:      COLONY_PLAN_FILE=agent-colony/plan.json $COLONY_SRC/plan.sh summary
```

Use the source directory from Step 1 for the full path.

### Bootstrap Guidelines

- **Aim for 3-8 tasks** for a typical feature. More than 10 suggests you're over-specifying.
- **Tasks are starting points.** Agents will add, split, and modify them. Don't try to be comprehensive.
- **Use the goal document's language** in task descriptions so agents can trace back to the source.
- **If the goal doc is very detailed** (like a design doc with implementation plan), extract the key deliverables as tasks. Don't create a 1:1 mapping of every section.
- **If the goal doc is minimal** (just a paragraph), create broader tasks and trust agents to break them down further.

---

## Run a Colony

Start the colony loop from the project root (where `agent-colony/` lives):

```bash
$COLONY_SRC/colony-build.sh [options] [max_iterations]
```

**Options:**
- `--agent <name>` — Agent to use: `codex` (default), `claude`
- `--goal <path>` — Path to goal document (or set `goalFile` in plan.json)
- `--review-every N` — Run reviewer every Nth iteration (default: 3)

**Example:**
```bash
nohup $COLONY_SRC/colony-build.sh --goal docs/plans/my-feature.md 250 > colony-build.log 2>&1 &
echo $!  # Save the PID
```

Use `nohup` + background so it survives terminal closure. Output goes to `colony-build.log`.

---

## Monitor a Running Colony

### Quick Health Check

```bash
COLONY_PLAN_FILE=agent-colony/plan.json $COLONY_SRC/plan.sh health
```

This shows:
- **Process status** — Is colony-build.sh running? PID, uptime
- **Progress** — Iterations completed, task counts, completion %
- **Velocity** — Tasks per 10 iterations, current task, longest stuck task
- **Health metrics** — No-op rate, no-op streaks, null taskWorked breakdown
- **Time metrics** — Avg time per iteration, last iteration age (requires timestamps)
- **Role distribution** — Implementer/reviewer/simplifier/validator split
- **Recent activity** — Last 5 iterations with role, task, and status
- **Warnings** — WARN/CRITICAL alerts for no-op rates, stuck tasks, thrash

### Task-Level Detail

```bash
COLONY_PLAN_FILE=agent-colony/plan.json $COLONY_SRC/plan.sh summary
```

Shows all tasks with status, votes, and descriptions.

### Raw Statistics

```bash
COLONY_PLAN_FILE=agent-colony/plan.json $COLONY_SRC/plan.sh stats
```

### View a Specific Task

```bash
COLONY_PLAN_FILE=agent-colony/plan.json $COLONY_SRC/plan.sh show T-007
```

### Tail the Colony Log

```bash
tail -f colony-build.log
```

---

## Manage a Running Colony

### Kill the Colony

```bash
kill $(pgrep -f colony-build.sh)
```

### Restart with Updated Prompts

If you've updated prompts, colony-build.sh, or plan.sh, the running colony won't pick up changes. Kill and restart:

```bash
kill $(pgrep -f colony-build.sh)
nohup $COLONY_SRC/colony-build.sh --goal docs/plans/my-feature.md 250 > colony-build.log 2>&1 &
```

### Fresh Start (Archive Old Run)

```bash
$COLONY_SRC/setup.sh --fresh
```

This archives the current plan.json and progress.txt, then reinitializes for a clean run.

---

## Key Files

| File | Location | Purpose |
|------|----------|---------|
| `plan.json` | `agent-colony/plan.json` | Task plan — tasks, votes, iteration log |
| `progress.txt` | `agent-colony/progress.txt` | Iteration log — what each agent did (skim last 10-15 entries) |
| `patterns.txt` | `agent-colony/patterns.txt` | Curated codebase conventions discovered by agents |
| `colony-build.log` | Project root | Full Codex output per iteration |
| `plan.sh` | `$COLONY_SRC/plan.sh` | CLI for querying/updating the plan |
| `colony-build.sh` | `$COLONY_SRC/colony-build.sh` | Main colony loop script |
