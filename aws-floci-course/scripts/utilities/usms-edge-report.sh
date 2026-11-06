#!/usr/bin/env bash
# USMS edge-readiness report (Lab 10 Exercise 3). Read-only.
#
# One JSON document on stdout: every usms- Lambda function with its runtime, memory,
# timeout, published versions, aliases, whether environment variables are set, and
# edge_eligible. Diagnostics go to stderr, so `usms-edge-report.sh | python3 -m json.tool`
# always sees clean JSON.
#
# edge_eligible is true only when ALL of these hold:
#   - runtime is Node.js or Python
#   - no environment variables
#   - no VPC configuration
#   - at least one published version
#   - memory <= 128 MB and timeout <= 5 s if the name contains "viewer",
#     otherwise memory <= 10240 MB and timeout <= 30 s (origin trigger caps)
# Each object also lists the reasons it is not eligible, so a false is explained.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# One call returns most of the configuration; the filter means no hard-coded list.
aws lambda list-functions \
  --query 'Functions[?starts_with(FunctionName, `usms-`)]' --output json > "$TMP/functions.json" \
  || { echo "list-functions failed" >&2; exit 2; }

for fn in $(python3 -c "import json,sys;print(' '.join(f['FunctionName'] for f in json.load(open(sys.argv[1]))))" "$TMP/functions.json"); do
  echo "reading $fn" >&2
  aws lambda list-versions-by-function --function-name "$fn" \
    --query "length(Versions[?Version!='\$LATEST'])" --output text > "$TMP/$fn.versions" 2>/dev/null || echo 0 > "$TMP/$fn.versions"
  aws lambda list-aliases --function-name "$fn" \
    --query 'length(Aliases)' --output text > "$TMP/$fn.aliases" 2>/dev/null || echo 0 > "$TMP/$fn.aliases"
done

python3 - "$TMP" << 'PY'
import json, os, sys
tmp = sys.argv[1]
out = []
for f in sorted(json.load(open(os.path.join(tmp, "functions.json"))), key=lambda x: x["FunctionName"]):
    name = f["FunctionName"]
    read = lambda ext: int((open(os.path.join(tmp, f"{name}.{ext}")).read().strip() or "0"))
    # .get() at every level: a function without Environment or VpcConfig has no such key
    env = (f.get("Environment") or {}).get("Variables") or {}
    vpc = (f.get("VpcConfig") or {}).get("SubnetIds") or []
    runtime, mem, timeout = f.get("Runtime", ""), f.get("MemorySize", 0), f.get("Timeout", 0)
    viewer = "viewer" in name
    cap_mem, cap_t = (128, 5) if viewer else (10240, 30)
    reasons = []
    if not runtime.startswith(("nodejs", "python")): reasons.append(f"runtime {runtime}")
    if env:                                           reasons.append(f"{len(env)} environment variables")
    if vpc:                                           reasons.append("VPC configuration")
    if read("versions") < 1:                          reasons.append("no published version")
    if mem > cap_mem:                                 reasons.append(f"memory {mem} > {cap_mem}")
    if timeout > cap_t:                               reasons.append(f"timeout {timeout} > {cap_t}")
    out.append({"name": name, "runtime": runtime, "memory": mem, "timeout": timeout,
                "versions": read("versions"), "aliases": read("aliases"),
                "env_vars": bool(env), "edge_eligible": not reasons,
                "not_eligible_because": reasons})
print(json.dumps(out, indent=2))
PY
