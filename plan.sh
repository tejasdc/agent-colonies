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
#   health                            Colony health and warning signals

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_FILE="${COLONY_PLAN_FILE:-$SCRIPT_DIR/plan.json}"

# Current iteration number (set by colony.sh via environment variable)
ITERATION="${COLONY_ITERATION:-0}"
ROLE="${COLONY_ROLE:-implementer}"

# Ensure plan file exists
if [ ! -f "$PLAN_FILE" ] && [ "$1" != "init" ] && [ "$1" != "health" ]; then
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

iso_to_epoch() {
  local iso_ts="$1"
  if [ -z "$iso_ts" ] || [ "$iso_ts" = "null" ]; then
    return 1
  fi

  if date -u -d "$iso_ts" +%s >/dev/null 2>&1; then
    date -u -d "$iso_ts" +%s
    return 0
  fi

  if date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_ts" +%s >/dev/null 2>&1; then
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_ts" +%s
    return 0
  fi

  return 1
}

lstart_to_epoch() {
  local lstart="$1"
  if [ -z "$lstart" ]; then
    return 1
  fi

  lstart=$(echo "$lstart" | xargs)

  if date -d "$lstart" +%s >/dev/null 2>&1; then
    date -d "$lstart" +%s
    return 0
  fi

  if date -j -f "%a %b %e %H:%M:%S %Y" "$lstart" +%s >/dev/null 2>&1; then
    date -j -f "%a %b %e %H:%M:%S %Y" "$lstart" +%s
    return 0
  fi

  return 1
}

format_duration_compact() {
  local seconds="$1"
  local days hours mins secs

  if [ -z "$seconds" ] || [ "$seconds" -lt 0 ] 2>/dev/null; then
    echo "unknown"
    return
  fi

  days=$((seconds / 86400))
  hours=$(((seconds % 86400) / 3600))
  mins=$(((seconds % 3600) / 60))
  secs=$((seconds % 60))

  if [ "$days" -gt 0 ]; then
    if [ "$hours" -gt 0 ]; then
      echo "${days}d${hours}h"
    else
      echo "${days}d"
    fi
  elif [ "$hours" -gt 0 ]; then
    echo "${hours}h${mins}m"
  elif [ "$mins" -gt 0 ]; then
    echo "${mins}m"
  else
    echo "${secs}s"
  fi
}

time_ago_from_iso() {
  local iso_ts="$1"
  local ts_epoch now_epoch diff

  ts_epoch=$(iso_to_epoch "$iso_ts" 2>/dev/null || true)
  if [ -z "$ts_epoch" ]; then
    return 1
  fi

  now_epoch=$(date +%s)
  diff=$((now_epoch - ts_epoch))
  if [ "$diff" -lt 0 ]; then
    diff=0
  fi

  printf "%s ago" "$(format_duration_compact "$diff")"
}

percent_of() {
  local n="$1"
  local d="$2"
  if [ "$d" -eq 0 ]; then
    echo "0"
  else
    awk -v n="$n" -v d="$d" 'BEGIN { printf "%.0f", (n*100)/d }'
  fi
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

  health)
    echo "=== Colony Health ==="
    echo ""

    PLAN_DISPLAY="$PLAN_FILE"
    if [[ "$PLAN_DISPLAY" == "$PWD/"* ]]; then
      PLAN_DISPLAY="${PLAN_DISPLAY#$PWD/}"
    fi

    if [ ! -f "$PLAN_FILE" ]; then
      echo "No plan.json found at $PLAN_DISPLAY."
      echo "Run colony-bootstrap or plan.sh init first."
      exit 0
    fi

    PROJECT_DIR=$(cd "$(dirname "$PLAN_FILE")/.." && pwd)
    COLONY_PIDS=$(pgrep -f "[c]olony-build.sh.*${PROJECT_DIR}" 2>/dev/null || true)
    PID_COUNT=$(printf "%s\n" "$COLONY_PIDS" | sed '/^$/d' | wc -l | tr -d ' ')

    PROCESS_LINE="Process: NOT RUNNING"
    if [ "$PID_COUNT" -gt 1 ]; then
      COLONY_PID=$(printf "%s\n" "$COLONY_PIDS" | sed '/^$/d' | tail -1)
      PROCESS_LINE="Process: RUNNING (PID $COLONY_PID, $PID_COUNT colony processes found - showing newest)"
    elif [ "$PID_COUNT" -eq 1 ]; then
      COLONY_PID=$(printf "%s\n" "$COLONY_PIDS" | sed '/^$/d')
      START_TIME=$(ps -o lstart= -p "$COLONY_PID" 2>/dev/null | sed 's/^ *//')
      START_EPOCH=$(lstart_to_epoch "$START_TIME" 2>/dev/null || true)
      if [ -n "$START_EPOCH" ]; then
        NOW_EPOCH=$(date +%s)
        ELAPSED_SECS=$((NOW_EPOCH - START_EPOCH))
        if [ "$ELAPSED_SECS" -lt 0 ]; then
          ELAPSED_SECS=0
        fi
        PROCESS_LINE="Process: RUNNING (PID $COLONY_PID, started $(format_duration_compact "$ELAPSED_SECS") ago)"
      else
        PROCESS_LINE="Process: RUNNING (PID $COLONY_PID)"
      fi
    fi

    BRANCH=$(jq -r '.branchName // ""' "$PLAN_FILE")
    GOAL=$(jq -r '.goalFile // ""' "$PLAN_FILE")
    if [ -z "$BRANCH" ]; then BRANCH="-"; fi
    if [ -z "$GOAL" ]; then GOAL="-"; fi

    echo "Plan: $PLAN_DISPLAY"
    echo "$PROCESS_LINE"
    echo "Branch: $BRANCH"
    echo "Goal: $GOAL"

    TOTAL_ITER=$(jq '.metadata.totalIterations // 0' "$PLAN_FILE")
    TASK_COUNT=$(jq '(.tasks // []) | length' "$PLAN_FILE")
    DONE_COUNT=$(jq '[((.tasks // [])[]?) | select(.status == "done")] | length' "$PLAN_FILE")
    IN_PROG_COUNT=$(jq '[((.tasks // [])[]?) | select(.status == "in-progress")] | length' "$PLAN_FILE")
    OPEN_COUNT=$(jq '[((.tasks // [])[]?) | select(.status == "open")] | length' "$PLAN_FILE")

    echo ""
    echo "--- Progress ---"
    echo "Iteration: $TOTAL_ITER"

    if [ "$TASK_COUNT" -eq 0 ]; then
      echo "No tasks created yet."
      exit 0
    fi

    echo "Tasks: $DONE_COUNT done, $IN_PROG_COUNT in-progress, $OPEN_COUNT open ($TASK_COUNT total)"

    if [ "$TOTAL_ITER" -eq 0 ]; then
      echo "No iterations yet."
      exit 0
    fi

    COMPLETION_PCT=$(percent_of "$DONE_COUNT" "$TASK_COUNT")
    echo "Completion: ${COMPLETION_PCT}%"

    echo ""
    echo "--- Velocity ---"
    VELOCITY=$(awk -v d="$DONE_COUNT" -v t="$TOTAL_ITER" 'BEGIN { printf "%.1f", (d*10)/t }')
    echo "Tasks completed per 10 iterations: $VELOCITY"

    CURRENT_TASK=$(jq -r '
      ([((.tasks // [])[]?) | select(.status == "in-progress")]) as $ip
      | if ($ip | length) == 0 then "none"
        else ($ip
          | map({id, claimed: (.claimedBy.iteration // 0)})
          | sort_by(.claimed)
          | .[-1]
          | "\(.id)|\(.claimed)")
        end
    ' "$PLAN_FILE")
    if [ "$CURRENT_TASK" = "none" ]; then
      echo "Current task: none"
    else
      CURRENT_TASK_ID="${CURRENT_TASK%%|*}"
      CURRENT_TASK_CLAIMED="${CURRENT_TASK##*|}"
      CURRENT_TASK_AGE=$((TOTAL_ITER - CURRENT_TASK_CLAIMED))
      if [ "$CURRENT_TASK_AGE" -lt 0 ]; then CURRENT_TASK_AGE=0; fi
      echo "Current task: $CURRENT_TASK_ID (claimed iter $CURRENT_TASK_CLAIMED, $CURRENT_TASK_AGE iters ago)"
    fi

    LONGEST_TASK=$(jq -r '
      ([((.tasks // [])[]?) | select(.status == "in-progress")]) as $ip
      | if ($ip | length) == 0 then "none"
        else ($ip
          | map({id, claimed: (.claimedBy.iteration // 0)})
          | sort_by(.claimed)
          | .[0]
          | "\(.id)|\(.claimed)")
        end
    ' "$PLAN_FILE")
    LONGEST_AGE=0
    LONGEST_TASK_ID=""
    if [ "$LONGEST_TASK" = "none" ]; then
      echo "Longest in-progress: none"
    else
      LONGEST_TASK_ID="${LONGEST_TASK%%|*}"
      LONGEST_TASK_CLAIMED="${LONGEST_TASK##*|}"
      LONGEST_AGE=$((TOTAL_ITER - LONGEST_TASK_CLAIMED))
      if [ "$LONGEST_AGE" -lt 0 ]; then LONGEST_AGE=0; fi
      if [ "$LONGEST_AGE" -ge 30 ]; then
        echo "Longest in-progress: $LONGEST_TASK_ID (${LONGEST_AGE}+ iterations)"
      else
        echo "Longest in-progress: $LONGEST_TASK_ID ($LONGEST_AGE iterations)"
      fi
    fi

    echo ""
    echo "--- Health Metrics ---"
    IMPLEMENTER_ITERS=$(jq '[((.metadata.iterationLog // [])[]?) | select(.role == "implementer")] | length' "$PLAN_FILE")
    IMPLEMENTER_NOOP=$(jq '[((.metadata.iterationLog // [])[]?) | select(.role == "implementer" and (.taskWorked == null or .taskWorked == ""))] | length' "$PLAN_FILE")
    IMPLEMENTER_NOOP_PCT=$(percent_of "$IMPLEMENTER_NOOP" "$IMPLEMENTER_ITERS")
    echo "No-op iterations: $IMPLEMENTER_NOOP/$IMPLEMENTER_ITERS (${IMPLEMENTER_NOOP_PCT}%)"

    NOOP_STREAK_CUR=$(jq '
      reduce ((.metadata.iterationLog // []
               | map(select(.role == "implementer"))
               | reverse)[]?) as $it
        ({count: 0, done: false};
          if .done then .
          elif ($it.taskWorked == null or $it.taskWorked == "") then .count += 1
          else .done = true
          end)
      | .count
    ' "$PLAN_FILE")
    NOOP_STREAK_MAX=$(jq '
      reduce ((.metadata.iterationLog // []
               | map(select(.role == "implementer")))[]?) as $it
        ({cur: 0, max: 0};
          if ($it.taskWorked == null or $it.taskWorked == "") then
            (.cur += 1 | .max = (if .cur > .max then .cur else .max end))
          else .cur = 0
          end)
      | .max
    ' "$PLAN_FILE")
    echo "No-op streak (current): $NOOP_STREAK_CUR"
    echo "No-op streak (max): $NOOP_STREAK_MAX"

    NULL_TASKWORKED_COUNT=$(jq '[((.metadata.iterationLog // [])[]?) | select(.taskWorked == null or .taskWorked == "")] | length' "$PLAN_FILE")
    NULL_TASKWORKED_PCT=$(percent_of "$NULL_TASKWORKED_COUNT" "$TOTAL_ITER")
    EXPECTED_NULL_COUNT=$(jq '[((.metadata.iterationLog // [])[]?) | select((.role == "reviewer" or .role == "simplifier" or .role == "validator") and (.taskWorked == null or .taskWorked == ""))] | length' "$PLAN_FILE")
    UNEXPECTED_NULL_COUNT=$(jq '[((.metadata.iterationLog // [])[]?) | select(.role == "implementer" and (.taskWorked == null or .taskWorked == ""))] | length' "$PLAN_FILE")
    echo "Null taskWorked: $NULL_TASKWORKED_COUNT/$TOTAL_ITER (${NULL_TASKWORKED_PCT}%)"
    echo "  - Reviewer/simplifier (expected): $EXPECTED_NULL_COUNT"
    echo "  - Implementer (unexpected): $UNEXPECTED_NULL_COUNT"

    echo ""
    echo "--- Time Metrics ---"
    HAS_TIMESTAMPS=$(jq '[(.metadata.iterationLog // [])[]? | select(.timestamp != null and .timestamp != "")] | length > 0' "$PLAN_FILE")
    if [ "$HAS_TIMESTAMPS" = "true" ]; then
      TS_COUNT=$(jq '[(.metadata.iterationLog // [])[]? | select(.timestamp != null and .timestamp != "")] | length' "$PLAN_FILE")
      FIRST_TS=$(jq -r '[(.metadata.iterationLog // [])[]? | select(.timestamp != null and .timestamp != "") | .timestamp] | .[0] // empty' "$PLAN_FILE")
      LAST_TS=$(jq -r '[(.metadata.iterationLog // [])[]? | select(.timestamp != null and .timestamp != "") | .timestamp] | .[-1] // empty' "$PLAN_FILE")
      LAST_TS_ITER=$(jq -r '[(.metadata.iterationLog // [])[]? | select(.timestamp != null and .timestamp != "")] | .[-1].iteration // 0' "$PLAN_FILE")
      FIRST_TS_EPOCH=$(iso_to_epoch "$FIRST_TS" 2>/dev/null || true)
      LAST_TS_EPOCH=$(iso_to_epoch "$LAST_TS" 2>/dev/null || true)

      if [ -n "$FIRST_TS_EPOCH" ] && [ -n "$LAST_TS_EPOCH" ] && [ "$TS_COUNT" -gt 0 ]; then
        AVG_MINUTES=$(awk -v first="$FIRST_TS_EPOCH" -v last="$LAST_TS_EPOCH" -v c="$TS_COUNT" 'BEGIN { d = last - first; if (d < 0) d = 0; printf "%.1f", (d/c)/60 }')
        echo "Avg time per iteration: $AVG_MINUTES min"
      else
        echo "Avg time per iteration: n/a"
      fi

      LAST_AGE=$(time_ago_from_iso "$LAST_TS" 2>/dev/null || true)
      if [ -n "$LAST_AGE" ]; then
        echo "Last iteration: #$LAST_TS_ITER, $LAST_AGE"
      else
        echo "Last iteration: #$LAST_TS_ITER"
      fi
    else
      echo "Not available (no timestamps in iterationLog)."
    fi

    echo ""
    echo "--- Role Distribution ---"
    IMPLEMENTER_COUNT=$(jq '[((.metadata.iterationLog // [])[]?) | select(.role == "implementer")] | length' "$PLAN_FILE")
    REVIEWER_COUNT=$(jq '[((.metadata.iterationLog // [])[]?) | select(.role == "reviewer")] | length' "$PLAN_FILE")
    SIMPLIFIER_COUNT=$(jq '[((.metadata.iterationLog // [])[]?) | select(.role == "simplifier")] | length' "$PLAN_FILE")
    VALIDATOR_COUNT=$(jq '[((.metadata.iterationLog // [])[]?) | select(.role == "validator")] | length' "$PLAN_FILE")
    echo "Implementer: $IMPLEMENTER_COUNT ($(percent_of "$IMPLEMENTER_COUNT" "$TOTAL_ITER")%)"
    echo "Reviewer: $REVIEWER_COUNT ($(percent_of "$REVIEWER_COUNT" "$TOTAL_ITER")%)"
    echo "Simplifier: $SIMPLIFIER_COUNT ($(percent_of "$SIMPLIFIER_COUNT" "$TOTAL_ITER")%)"
    echo "Validator: $VALIDATOR_COUNT ($(percent_of "$VALIDATOR_COUNT" "$TOTAL_ITER")%)"

    echo ""
    echo "--- Recent Activity (last 5 iterations) ---"
    jq -r '(.metadata.iterationLog // []) | .[-5:] | .[]?
      | "#\(.iteration // 0)\t\(.role // "-")\t\(.taskWorked // "-")\t\(
          if .role == "implementer" and (.taskWorked == null or .taskWorked == "")
          then "no-op"
          elif .role == "implementer" then "work"
          else (.role // "-")
          end)\t\(.timestamp // "")"' "$PLAN_FILE" \
    | while IFS=$'\t' read -r iter_num role_name task_worked action_label ts_raw; do
        AGE_LABEL=""
        if [ -n "$ts_raw" ]; then
          TS_AGE=$(time_ago_from_iso "$ts_raw" 2>/dev/null || true)
          if [ -n "$TS_AGE" ]; then
            AGE_LABEL="($TS_AGE)"
          fi
        fi
        printf "%-6s %-12s %-8s %-10s %s\n" "$iter_num" "$role_name" "$task_worked" "$action_label" "$AGE_LABEL"
      done

    if [ "$TOTAL_ITER" -ge 10 ]; then
      WARNINGS=()
      ITER_LOG_COUNT=$(jq '(.metadata.iterationLog // []) | length' "$PLAN_FILE")
      RECENT_IMPL_TOTAL=$(jq '((.metadata.iterationLog // []) | map(select(.role == "implementer")) | .[-30:]) | length' "$PLAN_FILE")
      RECENT_IMPL_NOOP=$(jq '((.metadata.iterationLog // []) | map(select(.role == "implementer")) | .[-30:]) as $s | [$s[]? | select(.taskWorked == null or .taskWorked == "")] | length' "$PLAN_FILE")

      if [ "$RECENT_IMPL_TOTAL" -ge 10 ]; then
        RECENT_IMPL_NOOP_RATE=$(awk -v n="$RECENT_IMPL_NOOP" -v d="$RECENT_IMPL_TOTAL" 'BEGIN { if (d == 0) print "0"; else printf "%.2f", (n*100)/d }')
        RECENT_IMPL_NOOP_PCT=$(percent_of "$RECENT_IMPL_NOOP" "$RECENT_IMPL_TOTAL")
        if awk -v r="$RECENT_IMPL_NOOP_RATE" 'BEGIN { exit !(r >= 50) }'; then
          WARNINGS+=("CRITICAL: $RECENT_IMPL_NOOP/$RECENT_IMPL_TOTAL recent implementer iterations produced no task work (${RECENT_IMPL_NOOP_PCT}%)")
        elif awk -v r="$RECENT_IMPL_NOOP_RATE" 'BEGIN { exit !(r >= 35) }'; then
          WARNINGS+=("WARN: $RECENT_IMPL_NOOP/$RECENT_IMPL_TOTAL recent implementer iterations produced no task work (${RECENT_IMPL_NOOP_PCT}%)")
        fi
      fi

      if [ "$NOOP_STREAK_CUR" -ge 6 ]; then
        WARNINGS+=("CRITICAL: Current implementer no-op streak is $NOOP_STREAK_CUR iterations")
      elif [ "$NOOP_STREAK_CUR" -ge 4 ]; then
        WARNINGS+=("WARN: Current implementer no-op streak is $NOOP_STREAK_CUR iterations")
      fi

      if [ "$IN_PROG_COUNT" -ge 3 ]; then
        WARNINGS+=("WARN: $IN_PROG_COUNT tasks are simultaneously in-progress (possible thrash)")
      fi

      if [ "$IN_PROG_COUNT" -gt 0 ] && [ -n "$LONGEST_TASK_ID" ]; then
        if [ "$LONGEST_AGE" -gt 30 ]; then
          WARNINGS+=("CRITICAL: $LONGEST_TASK_ID has been in-progress for $LONGEST_AGE iterations")
        elif [ "$LONGEST_AGE" -gt 15 ]; then
          WARNINGS+=("WARN: $LONGEST_TASK_ID has been in-progress for $LONGEST_AGE iterations")
        fi
      fi

      if [ "$ITER_LOG_COUNT" -ne "$TOTAL_ITER" ]; then
        WARNINGS+=("WARN: iterationLog count ($ITER_LOG_COUNT) differs from totalIterations ($TOTAL_ITER)")
      fi

      if [ "$HAS_TIMESTAMPS" != "true" ]; then
        WARNINGS+=("INFO: No timestamps in iterationLog; time metrics unavailable")
      fi

      echo ""
      echo "--- Warnings ---"
      if [ "${#WARNINGS[@]}" -eq 0 ]; then
        echo "No warnings."
      else
        for warning in "${WARNINGS[@]}"; do
          echo "$warning"
        done
      fi
    fi
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
    echo "  health                            Colony health and warning signals"
    echo ""
    echo "Environment:"
    echo "  COLONY_PLAN_FILE  Path to plan.json (default: ./plan.json)"
    echo "  COLONY_ITERATION  Current iteration number (set by colony.sh)"
    echo "  COLONY_ROLE       Current agent role (set by colony.sh)"
    ;;
esac
