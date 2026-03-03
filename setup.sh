#!/bin/bash
# Agent Colonies - Setup Script
# Run from your project root to initialize the agent-colony directory.
#
# Usage:
#   <agent-colonies-dir>/setup.sh [--fresh]
#
# Creates agent-colony/ with project-specific files only (plan.json, progress.txt).
# Shared files (prompts, scripts, docs) stay in the agent-colonies source.
#
# Options:
#   --fresh   Archive any existing run and start clean, even on the same branch.
#
# What this script does:
#   1. Checks prerequisites (jq, claude, codex)
#   2. If agent-colony/ exists with a previous run:
#      - Different branch → auto-archive old plan.json + progress.txt
#      - Same branch → resume (no archive, no reset)
#      - --fresh flag → always archive and reset
#   3. Creates agent-colony/ if it doesn't exist
#   4. Initializes progress.txt if it doesn't exist
#   5. Reports current state

set -e

# ─── Parse Arguments ──────────────────────────────────────────────────────────
FRESH=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --fresh) FRESH=true; shift ;;
    *) shift ;;
  esac
done

# ─── Paths ────────────────────────────────────────────────────────────────────
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"
TARGET_DIR="$PROJECT_DIR/agent-colony"
ARCHIVE_DIR="$TARGET_DIR/archive"
LAST_BRANCH_FILE="$TARGET_DIR/.last-branch"

echo "=== Agent Colony Setup ==="
echo "Project: $PROJECT_DIR"
echo "Data dir: $TARGET_DIR"
echo "Source: $SOURCE_DIR"
echo ""

# ─── Pre-flight ───────────────────────────────────────────────────────────────
if ! command -v jq &> /dev/null; then
  echo "Error: jq not found (required). Install: brew install jq"
  exit 1
fi

if ! command -v claude &> /dev/null; then
  echo "Warning: claude CLI not found. Install: npm install -g @anthropic-ai/claude-code"
fi

if ! command -v codex &> /dev/null; then
  echo "Warning: codex CLI not found. Install: npm install -g @openai/codex"
fi

# ─── Handle existing agent-colony/ ────────────────────────────────────────────
if [ -d "$TARGET_DIR" ] && [ -f "$TARGET_DIR/plan.json" ]; then
  EXISTING_BRANCH=$(jq -r '.branchName // empty' "$TARGET_DIR/plan.json" 2>/dev/null || echo "")
  EXISTING_TASKS=$(jq '.tasks | length' "$TARGET_DIR/plan.json" 2>/dev/null || echo "0")
  EXISTING_DONE=$(jq '[.tasks[] | select(.status == "done")] | length' "$TARGET_DIR/plan.json" 2>/dev/null || echo "0")

  echo "Found existing run:"
  echo "  Branch: ${EXISTING_BRANCH:-unknown}"
  echo "  Tasks: $EXISTING_DONE done / $EXISTING_TASKS total"

  SHOULD_ARCHIVE=false

  # Case 1: --fresh flag forces archive
  if [ "$FRESH" = true ]; then
    echo "  --fresh flag set, archiving existing run"
    SHOULD_ARCHIVE=true

  # Case 2: Branch changed (current git branch differs from last recorded branch)
  else
    CURRENT_GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "$EXISTING_BRANCH")
    if [ -n "$CURRENT_GIT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_GIT_BRANCH" != "$LAST_BRANCH" ]; then
      echo "  Branch changed: $LAST_BRANCH → $CURRENT_GIT_BRANCH"
      echo "  Archiving previous run"
      SHOULD_ARCHIVE=true
    fi

  # Case 3: Same branch, no --fresh → resume
  fi

  if [ "$SHOULD_ARCHIVE" = true ]; then
    DATE=$(date +%Y-%m-%d)
    FOLDER_NAME=$(echo "${EXISTING_BRANCH:-unknown}" | sed 's|^colony/||; s|/|-|g')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    # Handle duplicate archive names (multiple runs same day same branch)
    if [ -d "$ARCHIVE_FOLDER" ]; then
      COUNTER=1
      while [ -d "${ARCHIVE_FOLDER}-${COUNTER}" ]; do
        COUNTER=$((COUNTER + 1))
      done
      ARCHIVE_FOLDER="${ARCHIVE_FOLDER}-${COUNTER}"
    fi

    mkdir -p "$ARCHIVE_FOLDER"
    cp "$TARGET_DIR/plan.json" "$ARCHIVE_FOLDER/"
    [ -f "$TARGET_DIR/progress.txt" ] && cp "$TARGET_DIR/progress.txt" "$ARCHIVE_FOLDER/"
    echo "  Archived to: $ARCHIVE_FOLDER"

    # Reset for new run
    rm "$TARGET_DIR/plan.json"
    echo "# Agent Colony Progress Log" > "$TARGET_DIR/progress.txt"
    echo "Started: $(date)" >> "$TARGET_DIR/progress.txt"
    echo "---" >> "$TARGET_DIR/progress.txt"
    rm -f "$LAST_BRANCH_FILE"
    echo "  Reset for fresh start"
  else
    echo "  Resuming existing run (use --fresh to start over)"
  fi

  echo ""
fi

# ─── Create directory ─────────────────────────────────────────────────────────
mkdir -p "$TARGET_DIR"

# ─── Initialize progress file (skip if exists) ───────────────────────────────
if [ ! -f "$TARGET_DIR/progress.txt" ]; then
  echo "# Agent Colony Progress Log" > "$TARGET_DIR/progress.txt"
  echo "Started: $(date)" >> "$TARGET_DIR/progress.txt"
  echo "---" >> "$TARGET_DIR/progress.txt"
  echo "Created progress.txt"
else
  echo "progress.txt exists (preserved)"
fi

# ─── Report plan.json status ─────────────────────────────────────────────────
if [ -f "$TARGET_DIR/plan.json" ]; then
  TASK_COUNT=$(jq '.tasks | length' "$TARGET_DIR/plan.json" 2>/dev/null || echo "?")
  GOAL=$(jq -r '.goalFile // "not set"' "$TARGET_DIR/plan.json" 2>/dev/null || echo "?")
  DONE_COUNT=$(jq '[.tasks[] | select(.status == "done")] | length' "$TARGET_DIR/plan.json" 2>/dev/null || echo "?")
  echo "plan.json: $DONE_COUNT/$TASK_COUNT tasks done, goal: $GOAL"
else
  echo "No plan.json yet (create with /colony-bootstrap or manually)"
fi

# ─── Report ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Project files: $TARGET_DIR"
echo "Colony source: $SOURCE_DIR"
