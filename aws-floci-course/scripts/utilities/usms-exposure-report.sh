#!/usr/bin/env bash
# USMS exposure report (Lab 09 Exercise 3). Read-only. No arguments.
#
# One line per network interface in usms-vpc, with a verdict computed ONLY from
#   1. the route table of the interface's subnet (explicit association, else the main table)
#   2. the interface's public address (ENI association, else an Elastic IP on its instance)
#   3. the ingress rules of the groups the interface wears
# Names, tags and descriptions are printed for the reader and never used for a verdict.
#
# Verdicts:
#   EXPOSED                    igw route + public address + an ingress rule from 0.0.0.0/0
#   ADDRESSED, NO OPEN PORT    igw route + public address, but no ingress rule admits the
#                              internet. The internet can address it; the groups drop every
#                              packet. Not exposed today, one rule away from it.
#   NO PUBLIC ADDRESS          igw route, but nothing on the internet can address it
#   ISOLATED                   no igw route on its subnet's route table
#   ORPHANED                   interface not attached to anything (left by a terminated instance)
# 127.0.0.1 is loopback, not an internet address: Floci reports it for every instance, so it
# is ignored and noted.
#
# set -e is deliberately NOT used: a report must finish and say "unknown" when one lookup
# fails (a group not in the cache, a subnet with no explicit association), not stop half way.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true

VPC="${USMS_VPC_ID:-}"
[ -n "$VPC" ] && [ "$VPC" != "none" ] || { echo "USMS_VPC_ID is not set (configs/lab-02.env)" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/eni.json"     || echo '{"NetworkInterfaces":[]}' > "$TMP/eni.json"
aws ec2 describe-route-tables       --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/rt.json"      || echo '{"RouteTables":[]}'       > "$TMP/rt.json"
aws ec2 describe-security-groups    --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/sg.json"      || echo '{"SecurityGroups":[]}'    > "$TMP/sg.json"
aws ec2 describe-instances          --filters "Name=vpc-id,Values=$VPC" --output json > "$TMP/ec2.json"     || echo '{"Reservations":[]}'      > "$TMP/ec2.json"
aws ec2 describe-addresses                                              --output json > "$TMP/eip.json"     || echo '{"Addresses":[]}'         > "$TMP/eip.json"

python3 - "$TMP" "$REPO_ROOT/outputs/lab-09-exposure.json" << 'PY'
import ipaddress, json, os, subprocess, sys

tmp, out_path = sys.argv[1], sys.argv[2]
load = lambda n: json.load(open(os.path.join(tmp, n)))
enis   = load("eni.json")["NetworkInterfaces"]
tables = load("rt.json")["RouteTables"]
groups = {g["GroupId"]: g for g in load("sg.json")["SecurityGroups"]}
insts  = {i["InstanceId"]: i for r in load("ec2.json")["Reservations"] for i in r.get("Instances", [])}
eips   = load("eip.json")["Addresses"]

# subnet -> route table: an explicit association wins, otherwise the VPC's main table
main_rt, by_subnet = None, {}
for t in tables:
    for a in t.get("Associations", []):
        if a.get("Main"):
            main_rt = t
        if a.get("SubnetId"):
            by_subnet[a["SubnetId"]] = t

def igw_route(subnet):
    t = by_subnet.get(subnet, main_rt)
    if t is None:
        return None, "no route table"
    for r in t.get("Routes", []):
        if (r.get("GatewayId") or "").startswith("igw-") and r.get("DestinationCidrBlock") == "0.0.0.0/0":
            return True, t["RouteTableId"] + ("" if subnet in by_subnet else " (main)")
    return False, t["RouteTableId"] + ("" if subnet in by_subnet else " (main)")

def is_internet(ip):
    try:
        a = ipaddress.ip_address(ip)
    except Exception:
        return False
    return a.is_global

def public_address(eni):
    notes = []
    cands = [(eni.get("Association") or {}).get("PublicIp")]
    inst = (eni.get("Attachment") or {}).get("InstanceId")
    for e in eips:
        if e.get("NetworkInterfaceId") == eni["NetworkInterfaceId"] or (inst and e.get("InstanceId") == inst):
            cands.append(e.get("PublicIp"))
    if inst and inst in insts:
        cands.append(insts[inst].get("PublicIpAddress"))
    for c in cands:
        if c and is_internet(c):
            return c, notes
        if c == "127.0.0.1" and "loopback 127.0.0.1 ignored" not in notes:
            notes.append("loopback 127.0.0.1 ignored")
    return None, notes

def group(gid):
    """The cached group, or one fetched now if it was not in the VPC listing."""
    if gid in groups:
        return groups[gid]
    p = subprocess.run(["aws", "ec2", "describe-security-groups", "--group-ids", gid, "--output", "json"],
                       capture_output=True, text=True)
    try:
        groups[gid] = json.loads(p.stdout)["SecurityGroups"][0]
    except Exception:
        groups[gid] = None
    return groups[gid]

def world_ports(gids):
    ports, unknown = [], []
    for gid in gids:
        g = group(gid)
        if g is None:
            unknown.append(gid)
            continue
        for p in g.get("IpPermissions", []):
            if any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges", [])) or \
               any(r.get("CidrIpv6") == "::/0" for r in p.get("Ipv6Ranges", [])):
                lo = p.get("FromPort")
                ports.append("all" if lo is None else str(lo))
    return sorted(set(ports), key=lambda x: (x == "all", int(x) if x.isdigit() else 0)), unknown

def label(eni):
    inst = (eni.get("Attachment") or {}).get("InstanceId")
    if inst and inst in insts:
        tags = {t["Key"]: t["Value"] for t in insts[inst].get("Tags", [])}
        return tags.get("Name", inst), insts[inst].get("State", {}).get("Name")
    return eni.get("Description") or eni["NetworkInterfaceId"], None

rows = []
for e in sorted(enis, key=lambda x: x.get("PrivateIpAddress", "")):
    name, state = label(e)
    gids = [g["GroupId"] for g in e.get("Groups", [])]
    igw, rt = igw_route(e.get("SubnetId"))
    pub, notes = public_address(e)
    ports, unknown = world_ports(gids)
    attached = bool((e.get("Attachment") or {}).get("InstanceId")) and state != "terminated"
    if not attached:
        verdict, why = "ORPHANED", "attached to no running instance"
    elif igw is not True:
        verdict, why = "ISOLATED", f"no igw route on {rt}"
    elif not pub:
        verdict, why = "NO PUBLIC ADDRESS", f"igw route on {rt}, but no public address"
    elif ports:
        verdict, why = "EXPOSED", f"igw route + public address + sg allows {','.join(ports)} from 0.0.0.0/0"
    else:
        verdict, why = "ADDRESSED, NO OPEN PORT", "igw route + public address, but no ingress rule admits the internet"
    if unknown:
        why += f"; groups not readable: {','.join(unknown)}"
    if notes:
        why += f"; {'; '.join(notes)}"
    rows.append(dict(interface=e["NetworkInterfaceId"], name=name, private=e.get("PrivateIpAddress"),
                     public=pub, subnet=e.get("SubnetId"), route_table=rt, igw_route=igw,
                     groups=[(group(g) or {}).get("GroupName", g) for g in gids],
                     world_ports=ports, verdict=verdict, reason=why))

print("== USMS exposure report ==  (verdicts from routes, addresses and rules only)")
for r in rows:
    print(f"  {r['name']:<14} {r['private'] or '-':<12} {r['public'] or '-':<16} {r['verdict']:<24} ({r['reason']})")
counts = {}
for r in rows:
    counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
print("  " + "  ".join(f"{k}={v}" for k, v in sorted(counts.items())) + f"  interfaces={len(rows)}")
json.dump({"vpc": os.environ.get("USMS_VPC_ID"), "interfaces": rows}, open(out_path, "w"), indent=2)
PY
