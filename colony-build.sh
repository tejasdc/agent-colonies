#!/bin/bash
# colony-build.sh - Agent Colonies: stigmergy-inspired agent loop
#
# Run from your PROJECT ROOT (not from the agent-colonies source).
#
# Usage: colony-build.sh [options] [max_iterations]
#
# Options:
#   --agent <name>          Agent to use: codex (default), claude
#   --goal <path>           Path to goal document (or set goalFile in plan.json)
#   --review-every N        Run reviewer every Nth iteration (default: 5)
#   --simplify-every M      Run simplifier every Mth iteration (default: 7)
#
# Each iteration dispatches one agent in one role. The loop rotates roles
# (implementer, reviewer, simplifier, validator) across iterations.
#
# If max_iterations is not specified, defaults to 100.

set -e

# ─── Defaults ──────────────────────────────────────────────────────────────────
MAX_ITERATIONS=""
GOAL_FILE=""
AGENT="codex"        # Default agent (codex or claude)
REVIEW_EVERY=5       # Run reviewer every Nth iteration
SIMPLIFY_EVERY=7     # Run simplifier every Mth iteration

# ─── Parse Arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)          AGENT="$2"; shift 2 ;;
    --agent=*)        AGENT="${1#*=}"; shift ;;
    --goal)           GOAL_FILE="$2"; shift 2 ;;
    --goal=*)         GOAL_FILE="${1#*=}"; shift ;;
    --review-every)   REVIEW_EVERY="$2"; shift 2 ;;
    --simplify-every) SIMPLIFY_EVERY="$2"; shift 2 ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# ─── Paths ────────────────────────────────────────────────────────────────────
# SOURCE_DIR: where agent-colonies scripts, prompts, docs live (shared)
# PROJECT_DIR: the project being worked on (current working directory)
# DATA_DIR: project-specific colony data (plan.json, progress.txt)
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"
DATA_DIR="$PROJECT_DIR/agent-colony"
PLAN_FILE="$DATA_DIR/plan.json"
PROGRESS_FILE="$DATA_DIR/progress.txt"
PLAN_CLI="$SOURCE_DIR/plan.sh"
LAST_BRANCH_FILE="$DATA_DIR/.last-branch"
ARCHIVE_DIR="$DATA_DIR/archive"

# ─── Validate Numeric Options ────────────────────────────────────────────────
if ! [[ "$REVIEW_EVERY" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --review-every must be a positive integer (got '$REVIEW_EVERY')"
  exit 1
fi
if ! [[ "$SIMPLIFY_EVERY" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --simplify-every must be a positive integer (got '$SIMPLIFY_EVERY')"
  exit 1
fi

# ─── Pre-flight Checks ───────────────────────────────────────────────────────
# jq is required (plan management)
if ! command -v jq &> /dev/null; then
  echo "Error: jq not found. Install: brew install jq"
  exit 1
fi

# Verify the selected agent is available
case $AGENT in
  codex)
    if ! command -v codex &> /dev/null; then
      echo "Error: codex CLI not found. Install: npm install -g @openai/codex"
      echo "Or use --agent claude to use Claude Code instead."
      exit 1
    fi
    ;;
  claude)
    if ! command -v claude &> /dev/null; then
      echo "Error: claude CLI not found. Install: npm install -g @anthropic-ai/claude-code"
      exit 1
    fi
    ;;
  *)
    echo "Error: Unknown agent '$AGENT'. Supported: codex, claude"
    exit 1
    ;;
esac

# Verify agent-colony directory exists
if [ ! -d "$DATA_DIR" ]; then
  echo "Error: No agent-colony/ directory found at $DATA_DIR"
  echo "Run setup first: $SOURCE_DIR/setup.sh"
  exit 1
fi

# Verify plan.json exists
if [ ! -f "$PLAN_FILE" ]; then
  echo "Error: No plan.json found at $PLAN_FILE"
  echo "Run /colony-bootstrap in Claude Code, or create manually."
  exit 1
fi

# ─── Archive previous run if branch changed ───────────────────────────────────
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [ -f "$LAST_BRANCH_FILE" ]; then
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    DATE=$(date +%Y-%m-%d)
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^colony/||; s|/|-|g')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    cp "$PLAN_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "  Archived to: $ARCHIVE_FOLDER"

    # Clean up for new run — user must bootstrap again
    rm "$PLAN_FILE"
    echo "# Agent Colony Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
    rm -f "$LAST_BRANCH_FILE"
    echo ""
    echo "Branch changed. Previous plan archived."
    echo "Run /colony-bootstrap to create a new plan for branch '$CURRENT_BRANCH'."
    exit 0
  fi
fi

# Track current branch
if [ -n "$CURRENT_BRANCH" ]; then
  echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
fi

# Resolve goal file
if [ -z "$GOAL_FILE" ]; then
  GOAL_FILE=$(jq -r '.goalFile // empty' "$PLAN_FILE" 2>/dev/null)
fi
if [ -z "$GOAL_FILE" ] || [ ! -f "$PROJECT_DIR/$GOAL_FILE" ]; then
  echo "Error: Goal file not found. Specify with --goal <path> or set goalFile in plan.json."
  exit 1
fi

# Default max iterations
if [ -z "$MAX_ITERATIONS" ]; then
  MAX_ITERATIONS=100
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Agent Colony Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

# ─── Role Dispatch Logic ──────────────────────────────────────────────────────
# Determines which role runs for a given iteration number.
#
# Roles:
#   implementer - Gap analysis + TDD + implement + self-review (most iterations)
#   reviewer    - Code quality, advisory nudges, plan assessment (every Nth)
#   simplifier  - Refactor, deduplicate, extract utilities (every Mth)
#   validator   - Write e2e tests, verify feature completeness (when all tasks done)
#
# Priority: if divisible by both N and M, reviewer wins (quality first).
# Validator runs automatically when all tasks are done (not on a schedule).
get_role() {
  local iter=$1

  # Check if all tasks are done - trigger validator
  local open in_prog
  open=$(jq '[.tasks[] | select(.status == "open")] | length' "$PLAN_FILE" 2>/dev/null || echo "999")
  in_prog=$(jq '[.tasks[] | select(.status == "in-progress")] | length' "$PLAN_FILE" 2>/dev/null || echo "999")
  if [ "$open" -eq 0 ] && [ "$in_prog" -eq 0 ]; then
    local total
    total=$(jq '.tasks | length' "$PLAN_FILE" 2>/dev/null || echo "0")
    if [ "$total" -gt 0 ]; then
      echo "validator"
      return
    fi
  fi

  # Normal role dispatch
  if (( iter % REVIEW_EVERY == 0 )); then
    echo "reviewer"
  elif (( iter % SIMPLIFY_EVERY == 0 )); then
    echo "simplifier"
  else
    echo "implementer"
  fi
}

# ─── Prompt Building ──────────────────────────────────────────────────────────
# Each role gets its own prompt file from the source + runtime context injected.
build_prompt() {
  local role=$1
  local iteration=$2
  local prompt_file="$SOURCE_DIR/prompts/${role}.md"

  if [ ! -f "$prompt_file" ]; then
    echo "Error: Prompt file not found: $prompt_file"
    exit 1
  fi

  local runtime_context="[COLONY RUNTIME]
plan: agent-colony/plan.json
progress: agent-colony/progress.txt
patterns: agent-colony/patterns.txt
goal: ${GOAL_FILE}
project_root: ${PROJECT_DIR}
plan_cli: ${PLAN_CLI}
iteration: ${iteration}
role: ${role}

IMPORTANT — Colony Mode Override:
You are running inside an Agent Colony loop, NOT as a standalone agent session.
Your project may have AGENTS.md, CLAUDE.md, or similar instruction files that were
written for single-agent sessions. Some of their instructions CONFLICT with colony
workflow. Specifically:
- Do NOT use issue trackers (beads/bd, GitHub Issues) — use plan.sh for task management
- Do NOT push to remote (git push) — the colony operator handles that
- Do NOT follow session-completion workflows (landing the plane, bd sync, cleanup)
- Do NOT use tmux for test/command execution — run commands directly
- Do NOT delegate to other agents or spawn subagents — YOU are the agent
- DO use relevant codebase knowledge from those files (architecture, conventions, patterns)
Follow ONLY the colony workflow described below.
---
"
  echo "${runtime_context}$(cat "$prompt_file")"
}

# ─── Agent Dispatch ──────────────────────────────────────────────────────────
# Runs the prompt through the selected agent CLI.
# Both agents get full permissions — behavior is constrained by prompts, not sandboxes.
# This is safe because colony-build.sh runs inside isolated worktrees.
PROMPT_FILE="$DATA_DIR/.colony-prompt.md"

dispatch_agent() {
  local role=$1
  local prompt=$2

  # Write prompt to file (avoids shell quoting issues with long prompts)
  echo "$prompt" > "$PROMPT_FILE"

  case $AGENT in
    codex)
      codex exec --dangerously-bypass-approvals-and-sandbox "Read and follow the instructions in $PROMPT_FILE" 2>&1 || true
      ;;
    claude)
      cat "$PROMPT_FILE" | claude --dangerously-skip-permissions --print 2>&1 || true
      ;;
  esac

  rm -f "$PROMPT_FILE"
}

# ─── Main Loop ─────────────────────────────────────────────────────────────────
echo "============================================================="
echo "  Colony Build - Starting"
echo "  Agent: $AGENT"
echo "  Max iterations: $MAX_ITERATIONS"
echo "  Review every: $REVIEW_EVERY iterations"
echo "  Simplify every: $SIMPLIFY_EVERY iterations"
echo "  Goal: $GOAL_FILE"
echo "  Project: $PROJECT_DIR"
echo "  Source: $SOURCE_DIR"
echo "============================================================="
echo ""

CONSECUTIVE_VALIDATIONS=0
MAX_VALIDATIONS=3  # Safety: don't loop validators forever
FORCE_IMPLEMENTER=0  # Set by validation limit to override role dispatch

for i in $(seq 1 $MAX_ITERATIONS); do
  if [ "$FORCE_IMPLEMENTER" -eq 1 ]; then
    ROLE="implementer"
    FORCE_IMPLEMENTER=0
  else
    ROLE=$(get_role $i)
  fi

  # Track consecutive validations to detect completion
  if [ "$ROLE" = "validator" ]; then
    CONSECUTIVE_VALIDATIONS=$((CONSECUTIVE_VALIDATIONS + 1))
  else
    CONSECUTIVE_VALIDATIONS=0
  fi

  echo ""
  echo "============================================================="
  echo "  Iteration $i of $MAX_ITERATIONS"
  echo "  Role: $ROLE"
  OPEN=$(jq '[.tasks[] | select(.status == "open")] | length' "$PLAN_FILE" 2>/dev/null || echo "?")
  IN_PROG=$(jq '[.tasks[] | select(.status == "in-progress")] | length' "$PLAN_FILE" 2>/dev/null || echo "?")
  DONE=$(jq '[.tasks[] | select(.status == "done")] | length' "$PLAN_FILE" 2>/dev/null || echo "?")
  echo "  Tasks: $DONE done, $IN_PROG in-progress, $OPEN open"
  echo "============================================================="

  # Set environment variables for plan.sh to use
  export COLONY_ITERATION=$i
  export COLONY_ROLE=$ROLE
  export COLONY_PLAN_FILE=$PLAN_FILE

  # Build role-specific prompt and dispatch to agent
  PROMPT=$(build_prompt "$ROLE" "$i")
  dispatch_agent "$ROLE" "$PROMPT"

  # Detect which task was worked on by checking claims from this iteration
  TASK_WORKED=$(jq -r --argjson iter "$i" --arg role "$ROLE" \
    '[.tasks[] | select(.claimedBy.iteration == $iter and .claimedBy.role == $role)] | .[0].id // empty' \
    "$PLAN_FILE" 2>/dev/null || true)

  if [ -n "$TASK_WORKED" ]; then
    TASK_JSON="\"$TASK_WORKED\""
  else
    TASK_JSON="null"
  fi

  # Log this iteration in plan metadata (totalIterations increments across runs)
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg role "$ROLE" --argjson task "$TASK_JSON" --arg ts "$TIMESTAMP" \
     '.metadata.totalIterations = ((.metadata.totalIterations // 0) + 1) |
      .metadata.iterationLog += [{ iteration: (.metadata.totalIterations), role: $role, taskWorked: $task, contextCompacted: false, timestamp: $ts }]' \
     "$PLAN_FILE" > "${PLAN_FILE}.tmp" && mv "${PLAN_FILE}.tmp" "$PLAN_FILE"

  # Check for completion: validator ran and created no new tasks
  if [ "$ROLE" = "validator" ]; then
    NEW_OPEN=$(jq '[.tasks[] | select(.status == "open")] | length' "$PLAN_FILE" 2>/dev/null || echo "999")
    NEW_IN_PROG=$(jq '[.tasks[] | select(.status == "in-progress")] | length' "$PLAN_FILE" 2>/dev/null || echo "999")
    if [ "$NEW_OPEN" -eq 0 ] && [ "$NEW_IN_PROG" -eq 0 ]; then
      echo ""
      echo "============================================================="
      echo "  Colony Build Complete!"
      echo "  Validator confirmed: all tasks done, e2e tests passing"
      echo "  Finished at iteration $i of $MAX_ITERATIONS"
      echo "============================================================="
      echo "Check $PROGRESS_FILE for the full report."
      exit 0
    fi

    if [ "$CONSECUTIVE_VALIDATIONS" -ge "$MAX_VALIDATIONS" ]; then
      echo ""
      echo "Warning: $MAX_VALIDATIONS consecutive validations without completion."
      echo "Validator keeps finding issues. Forcing implementer on next iteration."
      CONSECUTIVE_VALIDATIONS=0
      FORCE_IMPLEMENTER=1
    fi
  fi

  echo ""
  echo "Iteration $i ($ROLE) complete."
  sleep 2
done

echo ""
echo "============================================================="
echo "  Colony Build reached max iterations ($MAX_ITERATIONS)."
OPEN=$(jq '[.tasks[] | select(.status == "open")] | length' "$PLAN_FILE" 2>/dev/null || echo "?")
IN_PROG=$(jq '[.tasks[] | select(.status == "in-progress")] | length' "$PLAN_FILE" 2>/dev/null || echo "?")
DONE=$(jq '[.tasks[] | select(.status == "done")] | length' "$PLAN_FILE" 2>/dev/null || echo "?")
echo "  Final: $DONE done, $IN_PROG in-progress, $OPEN open"
echo "============================================================="
echo "Check $PROGRESS_FILE for details."
echo "Run '$PLAN_CLI stats' for full statistics."
