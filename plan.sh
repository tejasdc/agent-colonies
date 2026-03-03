#!/bin/bash
# plan.sh - Plan management CLI for Agent Colonies
# A jq wrapper providing ergonomic commands for agents to query and update the plan.
#
# Usage:
#   ./plan.sh <command> [args]
#
# Commands:
#   init                              Initialize empty plan.json
#   summary                           Summary of all tasks (for gap analysis)
#   show <id>                         Full detail of one task
#   create --title "..." --desc "..." Create a new task
#   update <id> --status <status>     Update task status (open|in-progress|done)
#   update <id> --title "..."         Update task title
#   update <id> --desc "..."          Update task description
#   claim <id>                        Claim a task for current iteration
#   vote <id> <+1|-1> "reason"        Add a vote to a task
#   comment <id> "message"            Add a comment/nudge to a task
#   subtask add <id> "description"    Add a subtask
#   subtask done <id> <index>         Mark a subtask as done
#   subtask update <id> <index> "desc" Update a subtask description
#   subtask remove <id> <index>       Remove a subtask
#   split <id> "title1" "title2"      Split a task into two new tasks
#   stats                             Overall plan statistics

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_FILE="${COLONY_PLAN_FILE:-$SCRIPT_DIR/plan.json}"

# Current iteration number (set by colony.sh via environment variable)
ITERATION="${COLONY_ITERATION:-0}"
ROLE="${COLONY_ROLE:-implementer}"

# Ensure plan file exists
if [ ! -f "$PLAN_FILE" ] && [ "$1" != "init" ]; then
  echo "Error: No plan.json found at $PLAN_FILE"
  echo "Run './plan.sh init' to create one, or set COLONY_PLAN_FILE."
  exit 1
fi

# Generate next task ID
next_id() {
  local max
  max=$(jq -r '[.tasks[].id | ltrimstr("T-") | tonumber] | max // 0' "$PLAN_FILE")
  printf "T-%03d" $((max + 1))
}

# Temporary file for atomic updates
tmp_update() {
  local tmpfile="${PLAN_FILE}.tmp"
  cat > "$tmpfile"
  mv "$tmpfile" "$PLAN_FILE"
}

case "${1:-help}" in

  init)
    if [ -f "$PLAN_FILE" ]; then
      echo "Plan already exists at $PLAN_FILE"
      exit 1
    fi
    cat > "$PLAN_FILE" << 'INITJSON'
{
  "project": "",
  "branchName": "",
  "goalFile": "",
  "tasks": [],
  "metadata": {
    "createdAt": "",
    "totalIterations": 0,
    "iterationLog": []
  }
}
INITJSON
    # Set createdAt timestamp
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.metadata.createdAt = $ts' "$PLAN_FILE" | tmp_update
    echo "Initialized empty plan at $PLAN_FILE"
    ;;

  summary)
    jq -r '
      "PLAN SUMMARY",
      "===========",
      "Project: \(.project)",
      "Branch: \(.branchName)",
      "Goal: \(.goalFile)",
      "",
      "Tasks (\(.tasks | length) total):",
      "---",
      (.tasks[] |
        "[\(.status | ascii_upcase)] \(.id): \(.title)",
        "  Votes: +\([.votes[] | select(.value > 0)] | length) / -\([.votes[] | select(.value < 0)] | length) (net: \([.votes[].value] | add // 0))",
        "  Subtasks: \([.subtasks[] | select(.done)] | length)/\(.subtasks | length) done",
        if .claimedBy then "  Claimed by: iteration \(.claimedBy.iteration) (\(.claimedBy.role))" else "  Unclaimed" end,
        "---"
      ),
      "",
      "Stats: \([.tasks[] | select(.status == "done")] | length) done, \([.tasks[] | select(.status == "in-progress")] | length) in-progress, \([.tasks[] | select(.status == "open")] | length) open"
    ' "$PLAN_FILE"
    ;;

  show)
    if [ -z "$2" ]; then
      echo "Usage: ./plan.sh show <task-id>"
      exit 1
    fi
    jq --arg id "$2" '.tasks[] | select(.id == $id)' "$PLAN_FILE"
    ;;

  create)
    shift
    TITLE=""
    DESC=""
    while [[ $# -gt 0 ]]; do
      case $1 in
        --title) TITLE="$2"; shift 2 ;;
        --desc) DESC="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -z "$TITLE" ]; then
      echo "Usage: ./plan.sh create --title \"...\" --desc \"...\""
      exit 1
    fi
    NEW_ID=$(next_id)
    jq --arg id "$NEW_ID" \
       --arg title "$TITLE" \
       --arg desc "$DESC" \
       --argjson iter "$ITERATION" \
       --arg role "$ROLE" \
    '.tasks += [{
      id: $id,
      title: $title,
      description: $desc,
      subtasks: [],
      votes: [],
      comments: [],
      status: "open",
      createdBy: { iteration: $iter, role: $role },
      claimedBy: null,
      splitFrom: null
    }]' "$PLAN_FILE" | tmp_update
    echo "Created task $NEW_ID: $TITLE"
    ;;

  update)
    if [ -z "$2" ]; then
      echo "Usage: ./plan.sh update <task-id> --status <status> | --title \"...\" | --desc \"...\""
      exit 1
    fi
    TASK_ID="$2"
    shift 2
    while [[ $# -gt 0 ]]; do
      case $1 in
        --status)
          STATUS="$2"
          if [[ "$STATUS" != "open" && "$STATUS" != "in-progress" && "$STATUS" != "done" ]]; then
            echo "Error: status must be open, in-progress, or done"
            exit 1
          fi
          jq --arg id "$TASK_ID" --arg status "$STATUS" \
            '(.tasks[] | select(.id == $id)).status = $status' "$PLAN_FILE" | tmp_update
          echo "Updated $TASK_ID status to $STATUS"
          shift 2
          ;;
        --title)
          jq --arg id "$TASK_ID" --arg title "$2" \
            '(.tasks[] | select(.id == $id)).title = $title' "$PLAN_FILE" | tmp_update
          echo "Updated $TASK_ID title to: $2"
          shift 2
          ;;
        --desc)
          jq --arg id "$TASK_ID" --arg desc "$2" \
            '(.tasks[] | select(.id == $id)).description = $desc' "$PLAN_FILE" | tmp_update
          echo "Updated $TASK_ID description"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    ;;

  claim)
    if [ -z "$2" ]; then
      echo "Usage: ./plan.sh claim <task-id>"
      exit 1
    fi
    jq --arg id "$2" --argjson iter "$ITERATION" --arg role "$ROLE" \
      '(.tasks[] | select(.id == $id)) |= (.claimedBy = { iteration: $iter, role: $role } | .status = "in-progress")' \
      "$PLAN_FILE" | tmp_update
    echo "Claimed $2 for iteration $ITERATION ($ROLE)"
    ;;

  vote)
    if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
      echo "Usage: ./plan.sh vote <task-id> <+1|-1> \"reason\""
      exit 1
    fi
    TASK_ID="$2"
    VOTE_VAL="$3"
    REASON="$4"
    # Normalize vote value
    if [ "$VOTE_VAL" = "+1" ]; then
      VOTE_NUM=1
    elif [ "$VOTE_VAL" = "-1" ]; then
      VOTE_NUM=-1
    else
      echo "Error: vote must be +1 or -1"
      exit 1
    fi
    jq --arg id "$TASK_ID" \
       --argjson val "$VOTE_NUM" \
       --arg reason "$REASON" \
       --argjson iter "$ITERATION" \
       --arg role "$ROLE" \
      '(.tasks[] | select(.id == $id)).votes += [{ iteration: $iter, role: $role, value: $val, reason: $reason }]' \
      "$PLAN_FILE" | tmp_update
    echo "Voted $VOTE_VAL on $TASK_ID"
    ;;

  comment)
    if [ -z "$2" ] || [ -z "$3" ]; then
      echo "Usage: ./plan.sh comment <task-id> \"message\""
      exit 1
    fi
    jq --arg id "$2" \
       --arg msg "$3" \
       --argjson iter "$ITERATION" \
       --arg role "$ROLE" \
      '(.tasks[] | select(.id == $id)).comments += [{ iteration: $iter, role: $role, message: $msg }]' \
      "$PLAN_FILE" | tmp_update
    echo "Added comment to $2"
    ;;

  subtask)
    case "$2" in
      add)
        if [ -z "$3" ] || [ -z "$4" ]; then
          echo "Usage: ./plan.sh subtask add <task-id> \"description\""
          exit 1
        fi
        jq --arg id "$3" --arg desc "$4" \
          '(.tasks[] | select(.id == $id)).subtasks += [{ description: $desc, done: false }]' \
          "$PLAN_FILE" | tmp_update
        echo "Added subtask to $3"
        ;;
      done)
        if [ -z "$3" ] || [ -z "$4" ]; then
          echo "Usage: ./plan.sh subtask done <task-id> <index>"
          exit 1
        fi
        SUBTASK_LEN=$(jq --arg id "$3" '[.tasks[] | select(.id == $id)][0].subtasks | length' "$PLAN_FILE" 2>/dev/null || echo "0")
        if [ "$4" -lt 0 ] 2>/dev/null || [ "$4" -ge "$SUBTASK_LEN" ]; then
          echo "Error: subtask index $4 out of range (task $3 has $SUBTASK_LEN subtasks)"
          exit 1
        fi
        jq --arg id "$3" --argjson idx "$4" \
          '(.tasks[] | select(.id == $id)).subtasks[$idx].done = true' \
          "$PLAN_FILE" | tmp_update
        echo "Marked subtask $4 of $3 as done"
        ;;
      update)
        if [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ]; then
          echo "Usage: ./plan.sh subtask update <task-id> <index> \"new description\""
          exit 1
        fi
        SUBTASK_LEN=$(jq --arg id "$3" '[.tasks[] | select(.id == $id)][0].subtasks | length' "$PLAN_FILE" 2>/dev/null || echo "0")
        if [ "$4" -lt 0 ] 2>/dev/null || [ "$4" -ge "$SUBTASK_LEN" ]; then
          echo "Error: subtask index $4 out of range (task $3 has $SUBTASK_LEN subtasks)"
          exit 1
        fi
        jq --arg id "$3" --argjson idx "$4" --arg desc "$5" \
          '(.tasks[] | select(.id == $id)).subtasks[$idx].description = $desc' \
          "$PLAN_FILE" | tmp_update
        echo "Updated subtask $4 of $3"
        ;;
      remove)
        if [ -z "$3" ] || [ -z "$4" ]; then
          echo "Usage: ./plan.sh subtask remove <task-id> <index>"
          exit 1
        fi
        SUBTASK_LEN=$(jq --arg id "$3" '[.tasks[] | select(.id == $id)][0].subtasks | length' "$PLAN_FILE" 2>/dev/null || echo "0")
        if [ "$4" -lt 0 ] 2>/dev/null || [ "$4" -ge "$SUBTASK_LEN" ]; then
          echo "Error: subtask index $4 out of range (task $3 has $SUBTASK_LEN subtasks)"
          exit 1
        fi
        jq --arg id "$3" --argjson idx "$4" \
          '(.tasks[] | select(.id == $id)).subtasks |= del(.[$idx])' \
          "$PLAN_FILE" | tmp_update
        echo "Removed subtask $4 from $3"
        ;;
      *)
        echo "Usage: ./plan.sh subtask <add|done|update|remove> ..."
        exit 1
        ;;
    esac
    ;;

  split)
    if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
      echo "Usage: ./plan.sh split <task-id> \"new title 1\" \"new title 2\""
      exit 1
    fi
    ORIG_ID="$2"
    TITLE1="$3"
    TITLE2="$4"
    # Get original task description
    ORIG_DESC=$(jq -r --arg id "$ORIG_ID" '.tasks[] | select(.id == $id) | .description' "$PLAN_FILE")
    # Mark original as done with note about split
    jq --arg id "$ORIG_ID" \
      '(.tasks[] | select(.id == $id)).status = "done" |
       (.tasks[] | select(.id == $id)).comments += [{ iteration: '"$ITERATION"', role: "'"$ROLE"'", message: "Split into new tasks" }]' \
      "$PLAN_FILE" | tmp_update
    # Create two new tasks referencing the original
    ID1=$(next_id)
    jq --arg id "$ID1" \
       --arg title "$TITLE1" \
       --arg desc "Split from $ORIG_ID. Original: $ORIG_DESC" \
       --argjson iter "$ITERATION" \
       --arg role "$ROLE" \
       --arg orig "$ORIG_ID" \
    '.tasks += [{
      id: $id, title: $title, description: $desc,
      subtasks: [], votes: [], comments: [],
      status: "open",
      createdBy: { iteration: $iter, role: $role },
      claimedBy: null, splitFrom: $orig
    }]' "$PLAN_FILE" | tmp_update
    ID2=$(next_id)
    jq --arg id "$ID2" \
       --arg title "$TITLE2" \
       --arg desc "Split from $ORIG_ID. Original: $ORIG_DESC" \
       --argjson iter "$ITERATION" \
       --arg role "$ROLE" \
       --arg orig "$ORIG_ID" \
    '.tasks += [{
      id: $id, title: $title, description: $desc,
      subtasks: [], votes: [], comments: [],
      status: "open",
      createdBy: { iteration: $iter, role: $role },
      claimedBy: null, splitFrom: $orig
    }]' "$PLAN_FILE" | tmp_update
    echo "Split $ORIG_ID into $ID1 ($TITLE1) and $ID2 ($TITLE2)"
    ;;

  stats)
    jq -r '
      "PLAN STATISTICS",
      "===============",
      "Total tasks: \(.tasks | length)",
      "  Open: \([.tasks[] | select(.status == "open")] | length)",
      "  In Progress: \([.tasks[] | select(.status == "in-progress")] | length)",
      "  Done: \([.tasks[] | select(.status == "done")] | length)",
      "",
      "Total iterations: \(.metadata.totalIterations)",
      "  Implementer: \([.metadata.iterationLog[] | select(.role == "implementer")] | length)",
      "  Reviewer: \([.metadata.iterationLog[] | select(.role == "reviewer")] | length)",
      "  Simplifier: \([.metadata.iterationLog[] | select(.role == "simplifier")] | length)",
      "  Validator: \([.metadata.iterationLog[] | select(.role == "validator")] | length)",
      "",
      "Context compactions: \([.metadata.iterationLog[] | select(.contextCompacted)] | length)",
      "",
      "Most voted tasks:",
      (.tasks | sort_by(-([.votes[].value] | add // 0)) | .[:5][] |
        "  \(.id): \(.title) (net: \([.votes[].value] | add // 0))"
      )
    ' "$PLAN_FILE"
    ;;

  help|*)
    echo "plan.sh - Plan management CLI for Agent Colonies"
    echo ""
    echo "Usage: ./plan.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  init                              Initialize empty plan.json"
    echo "  summary                           Summary of all tasks"
    echo "  show <id>                         Full detail of one task"
    echo "  create --title \"...\" --desc \"...\" Create a new task"
    echo "  update <id> --status <status>     Update status (open|in-progress|done)"
    echo "  update <id> --title \"...\"         Update title"
    echo "  update <id> --desc \"...\"          Update description"
    echo "  claim <id>                        Claim task for current iteration"
    echo "  vote <id> <+1|-1> \"reason\"        Vote on a task"
    echo "  comment <id> \"message\"            Add a comment/nudge"
    echo "  subtask add <id> \"desc\"           Add a subtask"
    echo "  subtask done <id> <index>         Mark subtask as done"
    echo "  subtask update <id> <idx> \"desc\"  Update subtask description"
    echo "  subtask remove <id> <index>       Remove a subtask"
    echo "  split <id> \"title1\" \"title2\"      Split task into two"
    echo "  stats                             Overall statistics"
    echo ""
    echo "Environment:"
    echo "  COLONY_PLAN_FILE  Path to plan.json (default: ./plan.json)"
    echo "  COLONY_ITERATION  Current iteration number (set by colony.sh)"
    echo "  COLONY_ROLE       Current agent role (set by colony.sh)"
    ;;
esac
