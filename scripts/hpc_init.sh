#!/bin/bash
# Scaffold a project to use the genomedk-jobs skill: drop an hpc.env to fill in
# and gitignore the skill's local artifacts. Touches only the target directory
# and never contacts a cluster. Idempotent — it never overwrites an existing
# hpc.env, and never duplicates a .gitignore entry.
#
# Usage:
#   bash hpc_init.sh [target-dir]   # defaults to the current directory
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXAMPLE="$HERE/../config/hpc.env.example"
DEST_DIR="${1:-$PWD}"

[ -f "$EXAMPLE" ] || { echo "hpc_init: cannot find $EXAMPLE" >&2; exit 1; }
mkdir -p "$DEST_DIR"

cfg="$DEST_DIR/hpc.env"
if [ -e "$cfg" ]; then
    echo "hpc_init: $cfg already exists — leaving it untouched."
else
    cp "$EXAMPLE" "$cfg"
    echo "hpc_init: created $cfg from the example."
fi

# Gitignore the skill's local artifacts without creating duplicates.
gi="$DEST_DIR/.gitignore"
touch "$gi"
for pat in ".hpc_audit.log" ".hpc_root_verified" "__pycache__/"; do
    grep -qxF -- "$pat" "$gi" 2>/dev/null || printf '%s\n' "$pat" >> "$gi"
done
echo "hpc_init: ensured $gi ignores .hpc_audit.log, .hpc_root_verified, __pycache__/"

cat <<EOF

Next steps:
  1. Edit $cfg — set HPC_HOST, HPC_ACCOUNT, HPC_REMOTE_ROOT, HPC_PARTITION,
     HPC_MAIL_USER, HPC_PUSH_PATHS.
  2. Confirm ~/.ssh/config has the HPC_HOST alias (see reference/ssh_setup.md).
  3. Validate:  bash "$HERE/hpc_selftest.sh"
  4. Log in:    bash "$HERE/hpc_login.sh"   (you type the OTP)
EOF
