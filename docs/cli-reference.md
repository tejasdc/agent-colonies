# Plan CLI Reference

`plan.sh` is the agent-facing CLI for managing the colony's shared plan. It wraps jq operations on `plan.json` for safe, ergonomic task management.

## Environment Variables

Set automatically by `colony-build.sh`:

| Variable | Description |
|----------|-------------|
| `COLONY_PLAN_FILE` | Path to plan.json |
| `COLONY_ITERATION` | Current iteration number |
| `COLONY_ROLE` | Current agent role (implementer/reviewer/simplifier) |

## Commands

### Initialization

```bash
./plan.sh init
```
Creates an empty `plan.json` with metadata.

### Reading (No Mutations)

```bash
# Summary of all tasks - titles, statuses, vote counts, subtask progress
./plan.sh summary

# Full detail of one task - description, subtasks, all votes, all comments
./plan.sh show T-001

# Overall statistics - task counts, iteration counts, most voted tasks
./plan.sh stats
```

### Creating Tasks

```bash
./plan.sh create --title "Add priority field to database" --desc "Add a priority column..."
```
Generates sequential ID (T-001, T-002, etc.). Records which iteration/role created it.

### Updating Tasks

```bash
# Change status
./plan.sh update T-001 --status open
./plan.sh update T-001 --status in-progress
./plan.sh update T-001 --status done

# Update description (agents adding context from their analysis)
./plan.sh update T-001 --desc "Updated description with new details..."
```

### Claiming Tasks

```bash
./plan.sh claim T-001
```
Sets `claimedBy` to current iteration/role and status to `in-progress`. Use before starting implementation.

### Voting

```bash
./plan.sh vote T-001 +1 "Matches my independent gap analysis - this field is missing from schema"
./plan.sh vote T-001 -1 "This is already handled by the existing validation in utils/validate.ts"
```
Votes are the primary trace mechanism. Each vote records iteration, role, value, and reasoning.

### Comments / Nudges

```bash
./plan.sh comment T-001 "Consider reusing the existing Badge component instead of creating a new one"
```
Used primarily by reviewers. Advisory only - implementers decide whether to follow.

### Subtasks

```bash
# Add a subtask
./plan.sh subtask add T-001 "Create migration file with priority column"

# Mark subtask as done (0-indexed)
./plan.sh subtask done T-001 0

# Update a subtask description
./plan.sh subtask update T-001 0 "Create migration with priority column and default value"

# Remove a subtask that's no longer needed
./plan.sh subtask remove T-001 2
```

Agents should actively manage subtasks - not just add new ones but remove inaccurate ones and update descriptions that don't reflect reality.

### Splitting Tasks

```bash
./plan.sh split T-001 "Add priority column to schema" "Add priority to API responses"
```
Marks original task as done with a "split" comment. Creates two new tasks with `splitFrom` referencing the original. Both new tasks inherit the original's description as context.

## Typical Agent Workflow

### Implementer
```bash
# Phase 1-2: Read goal, analyze code, commits, tests independently
# Phase 3: THEN cross-reference the plan
./plan.sh summary                          # 1. See all tasks (after own analysis)
./plan.sh show T-003                       # 2. Inspect matching task
./plan.sh vote T-003 +1 "confirmed needed" # 3. Vote based on independent analysis
./plan.sh subtask add T-003 "Wire up API"  # 4. Add missing subtask
./plan.sh subtask remove T-003 1           # 5. Remove inaccurate subtask
./plan.sh claim T-003                      # 6. Claim it
# ... implement + self-review + self-reflect ...
./plan.sh subtask done T-003 0             # 7. Mark subtasks done
./plan.sh update T-003 --status done       # 8. Mark task done
```

### Reviewer
```bash
./plan.sh summary                          # 1. See all tasks
./plan.sh show T-003                       # 2. Inspect each task
./plan.sh vote T-003 +1 "well-scoped"     # 3. Vote
./plan.sh comment T-003 "Reuse existing X" # 4. Add nudge
./plan.sh create --title "Refactor: ..."   # 5. Create cleanup task if needed
```

### Simplifier
```bash
./plan.sh summary                          # 1. Check for refactor tasks
# ... review code for issues ...
# ... fix issues ...
./plan.sh update T-010 --status done       # 2. Mark cleanup task done
```
