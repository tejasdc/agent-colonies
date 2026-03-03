# Agent Colonies - Design Document

## Feature Overview

Agent Colonies is the evolution of Ralph Loops from a rigid PRD-driven task executor into a stigmergy-inspired, self-correcting agent loop system. Instead of requiring a fully detailed PRD with every task pre-defined, Agent Colonies takes a high-level goal and uses autonomous agents that independently assess the codebase, identify gaps, and collaboratively build a living plan through decentralized coordination.

## Background

### The Problem with Ralph Loops Today

Ralph operates as a **task queue executor**:
- A human creates a detailed PRD (`prd.json`) with every user story pre-defined
- `ralph.sh` spawns fresh agent instances in a loop
- Each agent picks the next `passes: false` story, implements it, marks it done
- Loop terminates when all stories pass

This is fragile because:
- **Static plans can't capture emergent work** - integration glue, wiring between components, and the "oh, these two things need to talk to each other" realizations only become obvious when code exists
- **PRDs miss gaps** - A human writing a PRD upfront is guessing at the task graph. Components get built in isolation but never integrated because "integrate A with B" wasn't in the plan
- **All-or-nothing input** - You either write a comprehensive PRD or you get incomplete results. There's no middle ground for "here's a rough goal, figure out the details"
- **No self-correction** - If the PRD is wrong or incomplete, agents follow it blindly. No mechanism to discover or fill gaps

### The Insight

The code itself is the oracle. An agent looking at actual code can *see* gaps that a human guessing upfront cannot. The detailed task breakdown should happen inside the loop - by agents who can assess real code state - not before it.

### Inspiration: Stigmergy

The design draws from stigmergy - how ants coordinate without a central plan by leaving traces in the environment. Key principles:
- **Decentralized coordination** - No central controller; agents communicate through shared artifacts
- **Traces in the environment** - Agents leave signals (votes, tasks, code) that guide future agents
- **Emergent prioritization** - The importance of work emerges from independent confirmation, not top-down assignment
- **Self-correction** - Bad decisions get overwritten by better ones as more agents assess the state

## Requirements

### Core Loop

Each agent iteration follows this workflow:

1. **Read the goal** - High-level objective from the user
2. **Read the environment** - Codebase + commit history + tests + progress log + plan (summary view)
3. **Compute the gap independently** - What's missing between reality and the goal?
4. **Cross-reference the plan** - Pull detail views on tasks that match the gap findings
5. **Decide** - Pick an existing task that matches (and +1 it), OR add a new task
6. **Update tasks** - Add votes, update subtasks, leave notes on relevant tasks
7. **Execute** - Implement the work (TDD: tests first, then implementation, then self-review)
8. **Report** - Update task status, append progress log with learnings

### Agent Model

**Decision: One agent per iteration, loop provides multi-perspective**

Each iteration runs a single agent in a single role. The agent does everything directly — reads code, writes code, runs tests, manages the plan. No intra-iteration orchestration or sub-agent dispatching.

The multi-perspective benefit (catching what one agent misses) comes from the **loop's role rotation**, not from multiple agents within a single iteration.

**Default agent:** Codex (`--agent codex`). Override with `--agent claude` for Claude Code.

| Agent | Invocation | Notes |
|-------|------------|-------|
| **Codex** (default) | `codex exec --full-auto` for implementer/simplifier/validator, `codex exec -s read-only` for reviewer | Reviewer gets read-only sandbox enforced by CLI |
| **Claude Code** | `claude --dangerously-skip-permissions --print` | Reviewer enforcement is prompt-based only |

**Why single-agent per iteration (not orchestrator + workers)?**
- The loop already provides multi-perspective through role rotation
- Simpler prompts (~100 lines vs ~250 lines) — less cognitive overhead per iteration
- Fewer failure modes (no background task management, no dispatch coordination)
- Cross-model verification can be added at the loop level later (e.g., different models for different roles)

**Future option: cross-model at loop level.** colony-build.sh could dispatch different agents for different roles (e.g., Codex for implementer, Claude for reviewer) without changing any prompts. The prompts say WHAT to do, the loop decides WHO does it.

### TDD Workflow (Implementer)

**Decision: TDD within a single agent session**

The implementer writes tests first, then implements, all as one continuous flow:

1. **Write test signatures and assertions** — define expected behavior, inputs/outputs, edge cases. Verify tests fail.
2. **Implement** — write code to make the tests pass. Follow existing codebase patterns.
3. **Run all tests** — new + existing. If failures, investigate both sides (test may be wrong OR implementation may be wrong).
4. **Self-review** — re-read the diff, check imports, integration, error handling, patterns.

**Why single-session TDD (not split across iterations)?**
- Natural flow — write test, see it fail, make it pass, all with full context
- Avoids coordination overhead of one agent writing tests and another implementing
- The reviewer role (every 3rd iteration) catches issues the self-review misses
- The validator role catches gaps at the end

### Agent Roles

Four distinct roles, rotated by the loop shell script:

| Role | Frequency | Job | Authority |
|------|-----------|-----|-----------|
| **Implementer** | Most iterations | Analyze gap, vote on tasks, TDD + implement + self-review | Full: creates tasks, writes code, updates plan |
| **Reviewer** | Every 3rd iteration | Code quality, tech debt, plan coherence, test coverage check | Advisory only: votes, comments, nudges |
| **Simplifier** | Every 7th iteration | Three-lens review (reuse, quality, efficiency), fix small issues | Code-level: refactors, creates cleanup tasks |
| **Validator** | When all tasks done | Write e2e tests, verify feature completeness | Creates new tasks from failures, confirms completion |

**Role rationale:**
- Implementers have final decision-making authority on what to build
- Reviewers run every 3rd iteration (more frequent than before) to compensate for the lack of intra-iteration review. They also check that implementers followed TDD
- Simplifiers act as the "evaporation" mechanism — removing unnecessary code, combining duplicates, keeping the codebase clean
- Validators are the final quality gate — write NEW e2e tests and create tasks from failures
- Reviewer and Simplifier roles prevent tech debt from accumulating until the end

**Independent analysis first:** All roles (especially implementers) form their own view of the codebase BEFORE reading the plan. This prevents plan anchoring and ensures fresh perspective each iteration.

### Voting Mechanism (Trace Strength)

The voting system is the primary trace mechanism. It provides emergent prioritization without centralized control.

- **+1 (positive vote)** - Agent independently confirmed this task is needed (with reasoning)
- **-1 (negative vote)** - Agent believes this task is unnecessary or wrong (with reasoning)
- Tasks with high net positive votes = high confidence, strong trace
- Tasks with negative votes carry warnings that implementers should consider
- **Stale tasks are never deleted** - they accumulate -1s and serve as a record of "we considered this and decided against it"
- **Reviewers can also vote** - adding their assessment to strengthen or weaken traces

### Task Structure

Tasks are living artifacts that agents collaboratively shape:

- **ID** - Unique identifier (e.g., T-001, T-002)
- **Title** - Short description of the work
- **Description** - What needs to happen (agents can update this as they learn more)
- **Subtasks** - Implementation steps within the task (agents add/update/remove these during analysis)
- **Votes** - Array of +1/-1 with reasoning and agent identifier (task level only, not subtask level)
- **Comments/Nudges** - From reviewers, advisory observations
- **Status** - open, in-progress, done
- **Created by** - Which iteration/agent created this task

**Agent powers over tasks:**
- **Create** new tasks from gap analysis
- **Update** descriptions and subtasks with missing context or steps
- **Split** tasks that have grown too large into multiple tasks
- **Vote** +1/-1 on existing tasks
- **Pick up** and implement tasks (claim for current iteration)

**Task granularity:**
- Tasks should be at roughly a user-story level - not as small as "add a single function" and not as large as "build entire feature"
- The right granularity emerges: if a task accumulates too many subtasks, agents should split it
- Each task should ideally be completable within one context window, but partial implementation is acceptable

### Partial Implementation

Context compaction is not fatal - it's degraded quality. The system handles partial work naturally:

- If context compacts mid-task, agent wraps up what it can, commits working code
- Agent marks task as in-progress (not done) with notes about where it got to
- Next implementer sees the in-progress task, reads notes + code, and continues
- Context compaction events tracked as a signal - frequent compaction suggests tasks are too coarse

### Goal Document

The goal document replaces the PRD as input. It's flexible in format and detail:

- **Minimal**: A paragraph describing the desired end state ("Migrate the app to React Native")
- **Medium**: End state + acceptance criteria + non-goals
- **Comprehensive**: Full design document from a brainstorming session

The system doesn't dictate format. The agent's gap analysis bridges whatever level of detail is provided.

### Completion

Two mechanisms work together:

1. **Validator cycle** - When all tasks are "done", a validator agent runs. It writes NEW e2e tests against the goal document. If tests pass and no new tasks are created, the colony is complete. If tests fail, new tasks are created and the colony continues.
2. **Hard iteration cutoff** - Safety net (MAX_ITERATIONS, default 100). Prevents infinite loops if the validator keeps finding issues.
3. **Consecutive validation limit** - If the validator runs 3 times in a row without completion, it switches back to implementer (prevents validator loops).

Unfinished tasks with accumulated -1 votes are expected and provide useful signal to the human reviewing results.

### Testing Guidelines (Guard Rail Testing)

All roles follow these testing tiers:

| Tier | When | What |
|------|------|------|
| **Tier 1: Always** | Ship with implementation | Data persistence, state transitions, security logic, pure functions, side effects |
| **Tier 2: On burn** | After a bug | Write regression test BEFORE fixing, then fix |
| **Tier 3: Never** | Skip | UI components, CSS, API response formatting, 3rd party behavior |

**Validator testing:** The validator does NOT hardcode a test framework. It discovers the project's testing approach by checking for local-test skills, existing test infrastructure (`package.json`, `jest.config`, etc.), existing test files, and CLAUDE.md instructions.

### Tooling: Plan Storage

**Decision: JSON file + jq queries, wrapped in a helper script (`plan.sh`)**

Rationale:
- jq provides both summary queries (for gap analysis) and targeted mutations (for updates)
- No external dependency (jq is ubiquitous, unlike Beads which requires Go/Dolt)
- Full control over schema - voting and nudges are first-class, not bolted on
- Helper script wraps common operations for safety and ergonomics

**Agent interaction pattern:**
1. Summary view (jq) - All tasks with titles, statuses, net votes → gap analysis
2. Detail view (jq) - Full task data for specific IDs → inspection before picking up
3. Targeted updates (jq) - Modify specific task fields without reading/writing full blob in context
4. Create/split - Add new tasks to the plan

**Considered alternatives:**
- **Beads CLI** - Battle-tested, has dependency tracking and ready detection, but adds significant dependency (Go binary + Dolt), and voting isn't native
- **Raw JSON without helper** - Too fragile; agents composing raw jq is error-prone
- **Markdown** - Harder for agents to parse and update programmatically than JSON

### Prompt Design

Each agent role gets a distinct prompt injected via the loop script. All prompts follow the same pattern:

- **Runtime context block** at the top (`[COLONY RUNTIME]`) with file paths and iteration info
- **Role-specific workflow** — phased instructions unique to each role
- **Principles** — role-specific decision-making guidance

Key design decisions in prompts:
- **No orchestration** — each agent does its work directly (reads, writes, tests, commits). No sub-agent dispatching.
- **Independent analysis before plan** — implementers form their own gap analysis BEFORE reading the plan to avoid anchoring
- **Recent history** — `git log --oneline -20` (works regardless of branch naming)
- **Self-review phase** — implementers re-read their diff and check for common issues before committing
- **Self-reflection phase** — implementers assess their own work before reporting
- **Reinforced patterns** — all roles cite existing patterns that proved helpful, strengthening traces

### Shell Script / Loop Orchestration

`colony-build.sh` manages the loop:
- Takes a goal document path, agent choice, and max iterations
- Dispatches the selected agent (`--agent codex` or `--agent claude`) for each iteration
- Assigns roles based on iteration number: reviewer > simplifier > implementer
- Reviewer runs every 3rd iteration (tighter feedback without intra-iteration review)
- Validator triggers automatically when all tasks are "done"
- Injects role-specific prompts with runtime context
- Writes prompt to temp file for Codex (avoids shell quoting issues with long prompts)
- Codex reviewer gets `-s read-only` sandbox; other roles get `--full-auto`
- Tracks iteration metadata in plan.json

### Setup Script

`setup.sh` creates `agent-colony/` in a project with project-specific files only:
- Creates `agent-colony/` directory
- Initializes `progress.txt` (skips if exists to preserve history)
- Archives previous runs when branch changes
- Checks for tool availability (jq, claude, codex)

Shared files (prompts, scripts, docs) stay in the agent-colonies source directory.

## Assumptions

1. A single agent per iteration can effectively do its role's work (analysis, coding, testing, reviewing)
2. The loop's role rotation provides sufficient multi-perspective benefit
3. A JSON plan file remains manageable in size for typical projects (dozens of tasks, not thousands)
4. Fresh context per iteration is maintained — each agent starts clean
5. The voting mechanism provides sufficient signal for emergent prioritization
6. Four agent roles (implementer, reviewer, simplifier, validator) are sufficient initially
7. The goal document is written by a human and does not change during the loop execution
8. jq is available in the project environment
9. TDD discipline is maintained through prompt instruction + reviewer enforcement

## Brainstorming & Investigation Findings

### Stigmergy Mapping

Initial attempt to map ant stigmergy directly (pheromone strength = partial implementation, evaporation = stale task timeout, exploration = random plan-ignoring) was too literal. The refined mapping:

- **Trace strength** = Voting mechanism (+1/-1). Independent confirmation from multiple agents that a task matters. This is genuinely emergent prioritization.
- **Evaporation** = Simplifier role. Removes unnecessary code, combines duplicates, creates shared utilities. Operates on code, not on the plan.
- **Exploration** = Freedom within task execution. Agents don't ignore the plan; they have latitude in HOW a task is done. Plus, any agent can create new tasks if its gap analysis reveals something the plan doesn't cover.

### The "Code as Oracle" Insight

The code is the source of truth for "where we are." The goal is the source of truth for "where we need to be." The plan captures agents' evolving understanding of the gap between the two. The plan is a shared notepad, not a predetermined checklist.

### Bottom-Up vs Top-Down

Early design considered making the reviewer a "plan curator" with authority to rewrite the plan. This was rejected as too centralized/top-down. Instead:
- Reviewers only add nudges, comments, and votes (advisory)
- Implementers make final decisions on what to build
- The plan emerges from collective agent behavior, not from a single controlling role

### TDD Decision

Evaluated three approaches for test-implementation sequencing:
- **Option A: Tests after implementation** — agent writes code, then writes tests. Risk: tests biased by what was implemented rather than what should have been.
- **Option B: Split TDD across iterations** — one agent writes tests, next agent implements. Risk: doubles iteration count per task, coordination overhead (test author makes interface assumptions).
- **Option C: TDD in single session** — SELECTED. Same agent writes tests first, verifies they fail, then implements to make them pass. Natural flow with full context. The reviewer role (every 3rd iteration) checks that TDD was actually followed.

### Single-Agent Per Iteration (Removing Orchestration)

Earlier design had Claude Code as orchestrator dispatching multiple Codex instances within each iteration (Test Codex → Implement Codex → Review Codex). This was removed because:
- The colony loop already provides multi-perspective through role rotation
- Orchestration added ~130 lines of prompt overhead per role (Codex CLI reference, dispatch templates, reconciliation logic)
- Fewer failure modes without background task management and cross-agent coordination
- Cross-model verification can be added at the loop level later (different `--agent` per role) without changing prompts

The prompts now say WHAT to do. The loop script decides WHO does it.

### Plan Storage Decision

Evaluated Beads CLI (Git-backed graph issue tracker by Steve Yegge). Beads offers excellent task infrastructure (dependency DAGs, ready detection, atomic claims, audit trails) but adds a significant external dependency and doesn't natively support our voting mechanism. JSON + jq was chosen for simplicity, zero dependencies, and full schema control.

Key concern addressed: even with Beads, agents still need to read all tasks for gap analysis. Beads' query advantage is real but not decisive given that jq provides adequate summary/detail/update capabilities.

## Options Explored

### Option 1: Evolve Ralph In-Place
Modify existing `ralph.sh`, `CLAUDE.md`, and `prd.json` to support the new model.
- **Pro**: No new repo, immediate integration
- **Con**: Breaks backward compatibility, existing Ralph users affected, harder to iterate

### Option 2: New Package (Agent Colonies) - SELECTED
Create a new repo (`agent-colonies`) that builds on Ralph's scaffolding but implements the new design.
- **Pro**: Clean slate, no backward compatibility concerns, can coexist with Ralph
- **Con**: Some code duplication initially

### Option 3: Plugin/Extension to Ralph
Add the new mode as an optional flag to Ralph (e.g., `--mode colony`).
- **Pro**: Single tool, shared infrastructure
- **Con**: Complicates Ralph's already simple design, conflates two different philosophies

**Decision**: Option 2. Agent Colonies is a new repo in the workspace directory, copying over what's needed from Ralph and building the new system as a separate package.

## Tradeoffs Made

1. **JSON over Beads** - Simplicity and zero dependencies over battle-tested infrastructure. Risk: we may need to build query tooling that Beads provides for free. Mitigation: helper script wraps common operations.

2. **Reviewer as advisor, not authority** - Bottom-up emergence over top-down control. Risk: plan may get messy with stale tasks. Mitigation: stale tasks accumulate -1s and implementers learn to ignore them; this is acceptable.

3. **Voting over automatic prioritization** - Manual +1/-1 from agents over algorithmic priority scoring. Risk: adds overhead to each iteration. Mitigation: voting is a lightweight step in the gap analysis phase, not a separate operation.

4. **New repo over evolving Ralph** - Clean design over backward compatibility. Risk: maintaining two systems. Mitigation: Agent Colonies can eventually supersede Ralph if proven.

5. **TDD in single session over split across iterations** — natural flow with full context over forced discipline via separation. Risk: agent may skip tests or write them retroactively. Mitigation: reviewer checks test coverage every 3rd iteration, validator runs e2e tests at the end.

6. **Single agent per iteration over orchestrator + workers** — simplicity and fewer failure modes over cross-model verification within each iteration. Risk: single model has blind spots. Mitigation: loop rotation provides multi-perspective; cross-model can be added at loop level later (`--agent` flag).

7. **Validator discovers testing approach** — no hardcoded test framework in the validator prompt. Risk: project without test infrastructure gets no validation. Mitigation: validator creates a task for test infrastructure if none exists.

8. **Reviewer every 3rd iteration** — more frequent reviews to compensate for removing intra-iteration review. Risk: more iterations spent reviewing instead of implementing. Mitigation: reviewer is lightweight (advisory only, no code changes), and the tighter feedback loop catches issues earlier.

## Implementation Plan

### Repository Structure (agent-colonies source — shared)
```
agent-colonies/
├── colony-build.sh        # Main loop script (run from project root)
├── plan.sh                # Plan management CLI (jq wrapper)
├── setup.sh               # Initializes agent-colony/ in a project
├── install.sh             # One-time global install (symlinks skills, stores path)
├── prompts/               # Agent prompts (shared, not copied)
│   ├── implementer.md
│   ├── reviewer.md
│   ├── simplifier.md
│   └── validator.md
├── skills/                # Skills (globally symlinked to ~/.claude/commands/)
│   └── colony-bootstrap/
│       └── SKILL.md
├── docs/
│   ├── agent-colonies-design.md
│   ├── cli-reference.md
│   └── plan-schema.md
├── plan.json.example
└── goal.md.example
```

### Global Config (created by install.sh)
```
~/.config/agent-colonies/
└── source-dir             # Absolute path to agent-colonies source
~/.claude/commands/
└── colony-bootstrap.md    # Symlink → skills/colony-bootstrap/SKILL.md
```

### Project-Specific Files (created by setup.sh)
```
my-project/
├── agent-colony/          # Only project-specific data
│   ├── plan.json          # Tasks, votes, comments
│   ├── progress.txt       # Agent progress log
│   ├── .last-branch       # Tracks current run for archiving
│   └── archive/           # Archived previous runs
│       └── 2026-03-01-feature-x/
│           ├── plan.json
│           └── progress.txt
└── ...                    # Rest of the project
```

### Distribution & Path Discovery

No hardcoded paths. The system uses a two-step discovery mechanism:

1. **`install.sh`** (run once after cloning) writes the source path to `~/.config/agent-colonies/source-dir`
2. **Skills and scripts** read that config file at runtime to find the source directory

This means:
- A new user clones the repo anywhere, runs `install.sh`, and everything works
- The `/colony-bootstrap` skill is the single entry point for new projects (it calls `setup.sh` internally)
- `colony-build.sh` derives its own source directory from its file path, so it works regardless of install location
- `plan.sh` uses `$COLONY_PLAN_FILE` env var set by `colony-build.sh`

**User workflow for a new install:**
```
git clone <repo> ~/wherever/agent-colonies
~/wherever/agent-colonies/install.sh
```

**User workflow per project:**
```
cd my-project/
/colony-bootstrap          # In Claude Code — runs setup.sh + creates plan.json
colony-build.sh            # Or full path if not in PATH
```

### Pending Work
- **Git worktrees** - Isolation mechanism for parallel agent work (deferred - awaiting user input)
- **Integration testing** - Run the colony on a real project to validate the design
