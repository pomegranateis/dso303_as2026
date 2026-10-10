#!/usr/bin/env bash
# Reachability report for every running Project=USMS instance.
# Verdict is computed from the subnet's route table and the instance's security groups,
# never from names or tags.
#
# set -e is deliberately OFF: describe-* calls legitimately return empty/None for some
# instances (no public IP, subnet on the main route table), and a missing field must
# produce a verdict, not abort the report for the remaining instances. -u and pipefail stay on.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

# Floci reports 127.0.0.1 as the "public" address; real AWS would never do that.
none() { [ -z "$1" ] || [ "$1" = "None" ] || [ "$1" = "null" ]; }

aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --query 'sort_by(Reservations[].Instances[], &InstanceId)[].[InstanceId,SubnetId,VpcId,PrivateIpAddress,PublicIpAddress,SecurityGroups[0].GroupId,Tags[?Key==`Name`]|[0].Value]' \
  --output text |
while IFS=$'\t' read -r id subnet vpc priv pub sg name; do
  none "$name" && name="$id"
  none "$pub" && pubshow="-" || pubshow="$pub"
  none "$priv" && priv="-"

  # IGW route: subnet's own table first, then the VPC main table.
  igw=$(aws ec2 describe-route-tables \
          --filters "Name=association.subnet-id,Values=$subnet" \
          --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' --output text 2>/dev/null)
  if none "$igw"; then
    igw=$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" \
            --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' --output text 2>/dev/null)
  fi

  # SG admits tcp/80 from 0.0.0.0/0 ?
  open80=$(aws ec2 describe-security-groups --group-ids "$sg" \
             --query 'length(SecurityGroups[0].IpPermissions[?FromPort==`80` && IpRanges[?CidrIp==`0.0.0.0/0`]])' \
             --output text 2>/dev/null)
  none "$open80" && open80=0

  case "$igw" in igw-*) has_igw=1 ;; *) has_igw=0 ;; esac

  if [ "$has_igw" -eq 0 ]; then
    verdict=UNREACHABLE; why="no igw route on subnet"
  elif [ "$open80" -eq 0 ]; then
    verdict=UNREACHABLE; why="igw route present but sg does not allow 80/tcp from 0.0.0.0/0"
  elif none "$pub"; then
    verdict=NO-ADDRESS;  why="igw route present but no public address"
  else
    verdict=REACHABLE;   why="igw route + sg allows 80/tcp from 0.0.0.0/0"
  fi

  printf '%-20s %-12s %-15s %-12s %s\n' "$name" "$priv" "$pubshow" "$verdict" "$why"
done
