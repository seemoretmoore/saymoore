#!/usr/bin/env bash
# Install git hooks from scripts/hooks/ into .git/hooks/ as symlinks.
# Re-run safely; symlinks are replaced.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
src_dir="$repo_root/scripts/hooks"
dst_dir="$repo_root/.git/hooks"

mkdir -p "$dst_dir"

for hook in "$src_dir"/*; do
  name="$(basename "$hook")"
  ln -sfn "../../scripts/hooks/$name" "$dst_dir/$name"
  chmod +x "$hook"
  echo "installed: $name"
done

echo
echo "Hooks installed. Set SKIP_PREPUSH=1 to bypass the pre-push build for a single push."
