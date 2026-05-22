#!/usr/bin/env bash
set -euo pipefail

echo "=== Ledger Setup ==="
echo ""

echo "Creating labels..."
gh label create "ledger/gap" --color "8b5cf6" --description "Pipeline gap detected by Ledger" 2>/dev/null \
  && echo "  Created: ledger/gap" \
  || echo "  Already exists: ledger/gap"

echo ""
echo "Setup complete."
echo ""
echo "Next: copy .github/workflows/ledger.yml from the submodule into your repo's .github/workflows/"
