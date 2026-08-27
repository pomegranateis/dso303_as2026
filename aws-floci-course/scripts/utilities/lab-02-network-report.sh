#!/usr/bin/env bash
# Report each subnet's status (PUBLIC/PRIVATE/ISOLATED), derived only
# from its effective route table's default route target — never from
# the subnet's name or tags.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

VPC_ID="${USMS_VPC_ID:-$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=usms-vpc" --query 'Vpcs[0].VpcId' --output text)}"

SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].SubnetId' --output text)

for s in $SUBNET_IDS; do
  name=$(aws ec2 describe-subnets --subnet-ids "$s" \
          --query 'Subnets[0].Tags[?Key==`Name`]|[0].Value' --output text)
  cidr=$(aws ec2 describe-subnets --subnet-ids "$s" \
          --query 'Subnets[0].CidrBlock' --output text)
  az=$(aws ec2 describe-subnets --subnet-ids "$s" \
          --query 'Subnets[0].AvailabilityZone' --output text)

  rt=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$s" \
        --query 'RouteTables[0].RouteTableId' --output text)

  igw=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
        --output text 2>/dev/null)
  nat=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId | [0]' \
        --output text 2>/dev/null)

  if [ -n "$igw" ] && [ "$igw" != "None" ]; then
    printf '%-24s %-13s %-12s PUBLIC   via %s\n' "$name" "$cidr" "$az" "$igw"
  elif [ -n "$nat" ] && [ "$nat" != "None" ]; then
    printf '%-24s %-13s %-12s PRIVATE  via %s\n' "$name" "$cidr" "$az" "$nat"
  else
    printf '%-24s %-13s %-12s ISOLATED no default route\n' "$name" "$cidr" "$az"
  fi
done
