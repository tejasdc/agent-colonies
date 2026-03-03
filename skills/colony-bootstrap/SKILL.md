---
name: colony-bootstrap
description: Bootstrap an Agent Colony plan from the current project's goal or design document. Runs setup, analyzes the codebase, reads the goal, and creates a plan.json with initial tasks. Use when starting a new colony.
---

# Bootstrap Colony Plan

You are seeding the initial plan for an Agent Colony. This involves two phases:
1. **Setup** (deterministic) — Run the setup script to create the `agent-colony/` directory and initialize project files
2. **Plan creation** (AI-powered) — Read the goal document, analyze the codebase, and create `plan.json` with tasks

The plan you create is a **starting point, not a finished spec**. Colony agents will vote on tasks, add subtasks, split large tasks, and create new tasks as they discover gaps. Don't try to capture everything — capture the obvious top-level work.

## Workflow

### Step 1: Find Source Directory & Run Setup

First, find the agent-colonies source directory. Read the config file written by `install.sh`:

```bash
cat ~/.config/agent-colonies/source-dir
```

This file contains the absolute path to the agent-colonies source (e.g., `/Users/alice/workspace/agent-colonies`). If the file doesn't exist, the user hasn't run `install.sh` yet — tell them to run it first from wherever they cloned the repo.

Then run the setup script using that path:

```bash
$(cat ~/.config/agent-colonies/source-dir)/setup.sh
```

This deterministically:
- Creates `agent-colony/` directory
- Initializes `progress.txt`
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

Next: Run colony-build.sh to start the colony loop.
      (Full path: <source-dir>/colony-build.sh)
```

Use the source directory from Step 1 for the full path.

## Guidelines

- **Aim for 3-8 tasks** for a typical feature. More than 10 suggests you're over-specifying.
- **Tasks are starting points.** Agents will add, split, and modify them. Don't try to be comprehensive.
- **Use the goal document's language** in task descriptions so agents can trace back to the source.
- **If the goal doc is very detailed** (like a design doc with implementation plan), extract the key deliverables as tasks. Don't create a 1:1 mapping of every section.
- **If the goal doc is minimal** (just a paragraph), create broader tasks and trust agents to break them down further.
