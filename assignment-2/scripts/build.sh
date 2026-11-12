#!/usr/bin/env bash
# Package each Lambda function into build/functions/<name>/ :
# its handler, the shared helpers in app/functions/common, and (for functions that
# use the database) the pinned dependencies. Terraform zips these directories.
# Set PIP_FIND_LINKS to a directory of wheels to build without network access.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build"
rm -rf "$OUT/deps" "$OUT/functions"
mkdir -p "$OUT/deps" "$OUT/functions"

# Resolve for the Lambda runtime (Python 3.12, x86_64), not for whatever Python runs
# this script: every dependency is a pure-Python wheel, so this is exact.
python3 -m pip install --quiet --disable-pip-version-check --no-compile --target "$OUT/deps" \
  --python-version 3.12 --implementation cp --platform manylinux2014_x86_64 --only-binary=:all: \
  --ignore-requires-python \
  ${PIP_FIND_LINKS:+--find-links "$PIP_FIND_LINKS"} -r "$ROOT/app/functions/requirements.txt"

for fn in exam_api submission_processor auto_marker notifier; do
  dst="$OUT/functions/$fn"
  mkdir -p "$dst"
  cp "$ROOT/app/functions/$fn/handler.py" "$dst/"
  cp "$ROOT/app/functions/common/"*.py "$dst/"
  if [ "$fn" != notifier ]; then cp -R "$OUT/deps/." "$dst/"; fi
  find "$dst" -name '__pycache__' -prune -exec rm -rf {} +
  printf 'built %-22s %s files\n' "$fn" "$(find "$dst" -type f | wc -l)"
done
