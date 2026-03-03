#!/bin/bash
# Agent Colonies - Global Install
# Run once after cloning the repo to set up global skills and PATH access.
#
# Usage:
#   git clone <repo-url> ~/workspace/agent-colonies
#   ~/workspace/agent-colonies/install.sh
#
# What this does:
#   1. Symlinks skills into ~/.claude/commands/ (available as /colony-bootstrap in Claude Code)
#   2. Makes scripts executable
#   3. Prints instructions for adding colony-build to PATH (optional)

set -e

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Agent Colonies - Global Install ==="
echo "Source: $SOURCE_DIR"
echo ""

# ─── Store source path for runtime discovery ─────────────────────────────────
# Skills and scripts read this file to find the agent-colonies source directory.
# This avoids hardcoding paths that differ per machine.
mkdir -p ~/.config/agent-colonies
echo "$SOURCE_DIR" > ~/.config/agent-colonies/source-dir
echo "Stored source path: ~/.config/agent-colonies/source-dir"

# ─── Make scripts executable ──────────────────────────────────────────────────
chmod +x "$SOURCE_DIR/colony-build.sh"
chmod +x "$SOURCE_DIR/plan.sh"
chmod +x "$SOURCE_DIR/setup.sh"
echo "Made scripts executable"

# ─── Symlink skills into global Claude commands ───────────────────────────────
mkdir -p ~/.claude/commands

LINKED=0
for skill_dir in "$SOURCE_DIR/skills"/*/; do
  skill_name=$(basename "$skill_dir")
  skill_file="$skill_dir/SKILL.md"
  link_target="$HOME/.claude/commands/${skill_name}.md"

  if [ -f "$skill_file" ]; then
    rm -f "$link_target"
    ln -s "$skill_file" "$link_target"
    echo "Linked skill: /$skill_name"
    LINKED=$((LINKED + 1))
  fi
done

if [ "$LINKED" -eq 0 ]; then
  echo "No skills found to link"
fi

# ─── Check prerequisites ─────────────────────────────────────────────────────
echo ""
echo "Prerequisites:"
for tool in jq claude codex; do
  if command -v $tool &> /dev/null; then
    echo "  $tool: installed"
  else
    echo "  $tool: NOT FOUND"
  fi
done

# ─── Instructions ─────────────────────────────────────────────────────────────
echo ""
echo "=== Install Complete ==="
echo ""
echo "Skills available in Claude Code:"
for skill_dir in "$SOURCE_DIR/skills"/*/; do
  skill_name=$(basename "$skill_dir")
  echo "  /$skill_name"
done
echo ""
echo "To start a colony on a project:"
echo "  cd your-project/"
echo "  /colony-bootstrap                  # Setup + seed tasks (in Claude Code)"
echo "  colony-build.sh [max_iterations]   # Run the colony loop"
echo ""
echo "Optional: add to PATH for shorter commands:"
echo "  echo 'export PATH=\"$SOURCE_DIR:\$PATH\"' >> ~/.zshrc"
echo "  source ~/.zshrc"
echo ""
echo "Without PATH, use the full path:"
echo "  $SOURCE_DIR/colony-build.sh [max_iterations]"
