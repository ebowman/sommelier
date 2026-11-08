#!/bin/sh
# Mutation run for the Lean model (slow: one full build per mutant). See lean/scripts/mutants.py.
set -e
cd "$(dirname "$0")/.."
exec python3 lean/scripts/mutants.py "$@"
