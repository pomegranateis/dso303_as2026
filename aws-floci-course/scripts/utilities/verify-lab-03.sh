#!/usr/bin/env bash
# Verify every Lab 03 artefact. Read-only. Exit 1 if anything fails.
# Checks labelled [floci] are expected to fail on this Floci build (see report).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env" 2>/dev/null || true

: "${USMS_VPC_ID:=none}"; : "${USMS_PUBLIC_SUBNET_A:=none}"; : "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_APP_SG:=none}"; : "${USMS_DB_SG:=none}"; : "${USMS_INSTANCE_PROFILE:=none}"
: "${USMS_WEB_INSTANCE:=none}"; : "${USMS_WEB2_INSTANCE:=none}"; : "${USMS_DB_INSTANCE:=none}"
: "${USMS_WEB_DATA_VOLUME:=none}"; : "${USMS_WEB_EIP_ALLOC:=none}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}
q() { aws ec2 describe-instances --instance-ids "$1" \
        --query "Reservations[0].Instances[0].$2" --output text; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"

echo "== Lab 01 and Lab 02 dependencies =="
check "usms-vpc still exists"       "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "usms-public-subnet-a exists" "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A"
check "usms-ec2-app-profile exists" "aws iam get-instance-profile --instance-profile-name $USMS_INSTANCE_PROFILE"

echo "== Key pair =="
check "key pair usms-app-key exists" "aws ec2 describe-key-pairs --key-names usms-app-key"
check "private key file present"     "test -f outputs/usms-app-key.pem"
check "private key is chmod 600" "test \"\$(stat -c '%a' outputs/usms-app-key.pem)\" = 600"

echo "== Web tier =="
check "usms-web-01 is running"  "test \"\$(q $USMS_WEB_INSTANCE State.Name)\" = running"
check "usms-web-01 is t3.micro" "test \"\$(q $USMS_WEB_INSTANCE InstanceType)\" = t3.micro"
check "usms-web-01 in usms-public-subnet-a" "test \"\$(q $USMS_WEB_INSTANCE SubnetId)\" = $USMS_PUBLIC_SUBNET_A"
check "usms-web-01 carries usms-app-sg" "test \"\$(q $USMS_WEB_INSTANCE 'SecurityGroups[0].GroupId')\" = $USMS_APP_SG"
check "usms-web-01 has instance profile usms-ec2-app-profile" \
  "q $USMS_WEB_INSTANCE 'IamInstanceProfile.Arn' | grep -q $USMS_INSTANCE_PROFILE"
check "an Elastic IP is associated with usms-web-01" \
  "test \"\$(aws ec2 describe-addresses --allocation-ids $USMS_WEB_EIP_ALLOC --query 'Addresses[0].InstanceId' --output text)\" = $USMS_WEB_INSTANCE"
check "usms-web-02 is running in a different AZ than web-01" \
  "test \"\$(q $USMS_WEB2_INSTANCE State.Name)\" = running && test \"\$(q $USMS_WEB2_INSTANCE 'Placement.AvailabilityZone')\" != \"\$(q $USMS_WEB_INSTANCE 'Placement.AvailabilityZone')\""
check "[floci] user data readable via describe-instance-attribute" \
  "test -n \"\$(aws ec2 describe-instance-attribute --instance-id $USMS_WEB_INSTANCE --attribute userData --query 'UserData.Value' --output text | grep -v '^None$')\""

echo "== Storage =="
check "usms-web-data-vol exists" "aws ec2 describe-volumes --volume-ids $USMS_WEB_DATA_VOLUME"
check "data volume is in the same AZ as web-01" \
  "test \"\$(aws ec2 describe-volumes --volume-ids $USMS_WEB_DATA_VOLUME --query 'Volumes[0].AvailabilityZone' --output text)\" = \"\$(q $USMS_WEB_INSTANCE 'Placement.AvailabilityZone')\""
check "[floci] data volume attached to usms-web-01 (attach-volume unsupported)" \
  "test \"\$(aws ec2 describe-volumes --volume-ids $USMS_WEB_DATA_VOLUME --query 'Volumes[0].Attachments[0].InstanceId' --output text)\" = $USMS_WEB_INSTANCE"
check "[floci] data volume DeleteOnTermination is False" \
  "test \"\$(aws ec2 describe-volumes --volume-ids $USMS_WEB_DATA_VOLUME --query 'Volumes[0].Attachments[0].DeleteOnTermination' --output text)\" = False"

echo "== Data tier =="
check "usms-db-01 is running" "test \"\$(q $USMS_DB_INSTANCE State.Name)\" = running"
check "usms-db-01 in usms-private-subnet-a" "test \"\$(q $USMS_DB_INSTANCE SubnetId)\" = $USMS_PRIVATE_SUBNET_A"
check "usms-db-01 carries usms-db-sg" "test \"\$(q $USMS_DB_INSTANCE 'SecurityGroups[0].GroupId')\" = $USMS_DB_SG"
check "usms-db-01 has NO instance profile" "test \"\$(q $USMS_DB_INSTANCE 'IamInstanceProfile.Arn')\" = None"
check "private subnet does not auto-assign public IPs" \
  "test \"\$(aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A --query 'Subnets[0].MapPublicIpOnLaunch' --output text)\" = False"
check "[floci] usms-db-01 has NO public address (Floci reports 127.0.0.1)" \
  "test \"\$(q $USMS_DB_INSTANCE PublicIpAddress)\" = None"
check "usms-db-sg has no CIDR-sourced ingress" \
  "test \"\$(aws ec2 describe-security-group-rules --filters Name=group-id,Values=$USMS_DB_SG --query 'length(SecurityGroupRules[?IsEgress==\`false\` && CidrIpv4!=\`null\`])' --output text)\" = 0"

echo "== Image =="
check "[floci] golden AMI exists (create-image unsupported)" \
  "aws ec2 describe-images --owners self --query 'Images[0].ImageId' --output text | grep -q '^ami-'"
check "base AMI recorded for Lab 08 fallback" "test -n \"\${USMS_BASE_AMI:-}\""

echo "== Tagging =="
check "three instances tagged Project=USMS" \
  "test \"\$(aws ec2 describe-instances --filters Name=tag:Project,Values=USMS Name=instance-state-name,Values=running --query 'length(Reservations[].Instances[])' --output text)\" -ge 3"

echo "== Files and Git hygiene =="
check "configs/lab-03.env exists" "test -f configs/lab-03.env"
check "configs/lab-03.env has no empty values" "! grep -qE 'export [A-Z_0-9]+=\$|=None\$' configs/lab-03.env"
check "user-data.sh parses" "bash -n labs/lab-03-ec2/user-data.sh"
check "run-instances request is valid JSON" "python3 -m json.tool templates/lab-03-run-instances.json"
check "private key is NOT tracked by git" "! git ls-files | grep -q 'usms-app-key.pem'"
check "private key is git-ignored" "git check-ignore -q outputs/usms-app-key.pem"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
