# Agent Colonies

A stigmergy-inspired, self-correcting agent loop that takes a high-level goal and autonomously builds software through decentralized coordination between AI agents.

Instead of requiring a detailed task list upfront, Agent Colonies takes a rough goal document, spawns autonomous agents in a loop, and lets them independently assess the codebase, identify gaps, vote on priorities, and collaboratively build a living plan — all while writing tested, reviewed code.

## How It Works

```
You write a goal  →  Agents analyze the code  →  They build a plan  →  They implement it
                         ↑                                                    ↓
                         └────────────── vote, review, simplify, validate ───┘
```

**The core insight:** The code itself is the oracle. An agent looking at actual code can see gaps that a human guessing upfront cannot. The detailed task breakdown happens inside the loop — by agents who can assess real code state — not before it.

### The Loop

Each iteration dispatches one agent in one role:

| Role | Frequency | Job |
|------|-----------|-----|
| **Implementer** | Most iterations | Gap analysis, TDD, implement, self-review |
| **Reviewer** | Every 3rd iteration | Code quality, plan coherence, advisory nudges |
| **Simplifier** | Every 7th iteration | Refactor, deduplicate, extract utilities |
| **Validator** | When all tasks done | Write e2e tests, verify feature completeness |

Agents coordinate through **traces** left in the environment (votes, tasks, comments, code, tests) — not through a central controller. This is inspired by [stigmergy](https://en.wikipedia.org/wiki/Stigmergy), the mechanism ants use to coordinate without a central plan.

### Voting as Emergent Prioritization

Every agent independently analyzes the codebase and votes on tasks:
- **+1** — "I independently confirmed this task is needed" (with reasoning)
- **-1** — "I believe this task is unnecessary or wrong" (with reasoning)

High net-positive votes = high confidence the work matters. Tasks are never deleted — negative votes serve as warnings and historical record.

## Prerequisites

- [jq](https://jqlang.github.io/jq/) — `brew install jq`
- At least one AI agent CLI:
  - [Codex](https://github.com/openai/codex) (default) — `npm install -g @openai/codex`
  - [Claude Code](https://github.com/anthropics/claude-code) — `npm install -g @anthropic-ai/claude-code`

## Install

```bash
git clone https://github.com/tejasdc/agent-colonies.git ~/workspace/agent-colonies
~/workspace/agent-colonies/install.sh
```

This does three things:
1. Stores the source path at `~/.config/agent-colonies/source-dir` (for runtime discovery)
2. Symlinks the `/colony-bootstrap` skill into `~/.claude/commands/` (available in Claude Code)
3. Makes all scripts executable

Optionally add to PATH for shorter commands:
```bash
echo 'export PATH="$HOME/workspace/agent-colonies:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## Quick Start

### 1. Write a goal document in your project

Create a `goal.md` (or any markdown file) describing what you want built:

```markdown
# Goal: User Authentication

## Desired End State
Users can sign up, log in, and log out. Sessions persist across page refreshes.

## Key Outcomes
- Email/password signup with validation
- Login with session cookie
- Protected routes redirect to login
- Logout clears session

## Non-Goals
- OAuth/social login
- Password reset flow
- Email verification
```

The goal can be minimal (a paragraph) or comprehensive (a full design doc). Agents bridge the gap.

### 2. Bootstrap the colony

In Claude Code, from your project root:
```
/colony-bootstrap
```

This runs `setup.sh` to create the `agent-colony/` directory, then analyzes your codebase and goal to create an initial `plan.json` with tasks.

Or manually:
```bash
# Run setup
$(cat ~/.config/agent-colonies/source-dir)/setup.sh

# To start fresh (archive existing run on same branch)
$(cat ~/.config/agent-colonies/source-dir)/setup.sh --fresh

# Then create plan.json manually or via /colony-bootstrap in Claude Code
```

### 3. Run the colony loop

```bash
colony-build.sh                          # Uses Codex by default, 100 iterations max
colony-build.sh --agent claude           # Use Claude Code instead
colony-build.sh --agent codex 50         # Codex, max 50 iterations
colony-build.sh --review-every 5         # Reviewer every 5th iteration
colony-build.sh --goal docs/spec.md 30   # Custom goal file, 30 iterations
```

The loop runs until either:
- The validator confirms all tasks are done and e2e tests pass
- Max iterations reached (default 100)

Safety mechanisms:
- If the validator runs 3 times consecutively without completion, it forces an implementer iteration to break the loop
- Previous runs are automatically archived when you switch git branches

### 4. Check progress

From your project root:

```bash
# Set the plan file path (or add to your shell profile)
export COLONY_PLAN_FILE=agent-colony/plan.json

# Task summary with statuses, votes, and subtask progress
$(cat ~/.config/agent-colonies/source-dir)/plan.sh summary

# Overall statistics
$(cat ~/.config/agent-colonies/source-dir)/plan.sh stats

# Full detail on a specific task
$(cat ~/.config/agent-colonies/source-dir)/plan.sh show T-001

# Read the progress log
cat agent-colony/progress.txt
```

Note: `plan.sh` reads `$COLONY_PLAN_FILE` to find the plan. This is set automatically during `colony-build.sh` runs, but must be set manually when using `plan.sh` standalone. Without it, `plan.sh` looks for `plan.json` in the agent-colonies source directory.

## Project Structure

### Agent Colonies Source (shared, cloned once)
```
agent-colonies/
├── colony-build.sh        # Main loop script
├── plan.sh                # Plan management CLI (jq wrapper)
├── setup.sh               # Initializes agent-colony/ in a project
├── install.sh             # One-time global install
├── prompts/               # Agent role prompts
│   ├── implementer.md     # Gap analysis + TDD + implement + self-review
│   ├── reviewer.md        # Code quality + plan coherence + advisory nudges
│   ├── simplifier.md      # Three-lens review (reuse, quality, efficiency)
│   └── validator.md       # E2E tests + feature completeness verification
├── skills/
│   └── colony-bootstrap/
│       └── SKILL.md       # Claude Code skill for bootstrapping
├── docs/
│   ├── agent-colonies-design.md   # Full design document
│   ├── cli-reference.md           # plan.sh command reference
│   └── plan-schema.md             # plan.json schema documentation
├── goal.md.example        # Example goal document
└── plan.json.example      # Example plan with votes, comments, subtasks
```

### Per-Project Files (created by setup.sh)
```
your-project/
└── agent-colony/
    ├── plan.json          # Tasks, votes, comments (the living plan)
    ├── progress.txt       # Agent progress log with learnings
    ├── .last-branch       # Tracks current branch for archiving
    └── archive/           # Archived plans from previous runs
```

## Plan Management CLI

`plan.sh` is how agents (and you) interact with the plan:

```bash
plan.sh summary                           # All tasks with statuses and votes
plan.sh show T-001                        # Full task detail
plan.sh create --title "..." --desc "..." # Create a task
plan.sh update T-001 --status done        # Update status
plan.sh claim T-001                       # Claim for current iteration
plan.sh vote T-001 +1 "reason"            # Vote on a task
plan.sh comment T-001 "advisory note"     # Leave a nudge
plan.sh subtask add T-001 "step"          # Add a subtask
plan.sh subtask done T-001 0              # Mark subtask done
plan.sh split T-001 "part A" "part B"     # Split a large task
plan.sh stats                             # Overall statistics
```

See [docs/cli-reference.md](docs/cli-reference.md) for full documentation.

## Agent Roles in Detail

### Implementer (most iterations)
1. Reads the goal and analyzes the codebase independently (before looking at the plan)
2. Cross-references findings against the plan — votes on tasks, adds/removes subtasks
3. Picks the highest-voted open task and claims it
4. Writes tests first (TDD), then implements, then self-reviews
5. Commits working code and reports learnings

### Reviewer (every 3rd iteration)
- Reviews recent code changes for quality, patterns, and coverage
- Assesses plan coherence — votes on tasks, leaves advisory comments
- Creates refactoring tasks for the simplifier
- **Does not write code** (advisory only)

### Simplifier (every 7th iteration)
- Reviews through three lenses: code reuse, code quality, efficiency
- Fixes small issues directly (extract utilities, remove duplication)
- Creates tasks for larger refactors
- Runs all tests after changes

### Validator (when all tasks are done)
- Discovers the project's testing approach (no hardcoded framework)
- Writes e2e tests against the goal document
- If tests pass → colony complete
- If tests fail → creates new tasks, colony continues

## Design Philosophy

**The plan is a shared notepad, not a predetermined checklist.** It captures agents' evolving understanding of the gap between the goal and reality.

**Bottom-up over top-down.** Reviewers advise — they don't direct. Implementers have final decision-making authority. Priorities emerge from collective voting, not central assignment.

**Independent analysis prevents anchoring.** Every implementer forms their own view of the codebase before reading the plan. This ensures fresh perspective each iteration.

**Partial work is fine.** If an agent's context compacts mid-task, it wraps up what it can and the next agent continues. Context compaction events are tracked as signals.

**Tasks are never deleted.** They accumulate votes and serve as historical record. Negative votes are warnings, not deletions.

For the full design rationale, see [docs/agent-colonies-design.md](docs/agent-colonies-design.md).

## Configuration

| Flag | Default | Description |
|------|---------|-------------|
| `--agent <name>` | `codex` | Agent CLI to use (`codex` or `claude`) |
| `--goal <path>` | from plan.json | Path to goal document |
| `--review-every N` | `3` | Run reviewer every Nth iteration |
| `--simplify-every M` | `7` | Run simplifier every Mth iteration |
| `[max_iterations]` | `100` | Safety cutoff for the loop |

## License

MIT
