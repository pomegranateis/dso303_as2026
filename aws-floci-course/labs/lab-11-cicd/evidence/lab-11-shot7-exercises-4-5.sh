#!/usr/bin/env bash
# Lab 11 screenshot 7 - Exercises 4-5 (live readback)
cd ~/dso303_as2026/aws-floci-course && source configs/course.env; export AWS_PAGER=""
D=$(mktemp -d)
echo "== Ex4: rule, target and target role =="
aws events describe-rule --name usms-enrolment-source-changed --query '[Name,State]' --output text
aws events describe-rule --name usms-enrolment-source-changed --query EventPattern --output text | python3 -c 'import json,sys; p=json.load(sys.stdin); print("  pattern: source=%s detail-type=%s bucket=%s key=%s" % (p["source"][0], p["detail-type"][0], p["detail"]["bucket"]["name"][0], p["detail"]["object"]["key"][0]))'
aws events list-targets-by-rule --rule usms-enrolment-source-changed --query 'Targets[0].[Arn,RoleArn]' --output text | awk '{print "  target: " $1 "  RoleArn=" $2}'
R=arn:aws:iam::000000000000:role/usms-events-pipeline-role
for a in "codepipeline:StartPipelineExecution arn:aws:codepipeline:us-east-1:000000000000:usms-enrolment-pipeline" "iam:PassRole arn:aws:iam::000000000000:role/usms-codepipeline-role"; do
  printf '  role may %-36s on %-22s %s\n' "${a%% *}" "${a##*[:/]}" "$(aws iam simulate-principal-policy --policy-source-arn $R --action-names ${a%% *} --resource-arns ${a#* } --query 'EvaluationResults[0].EvalDecision' --output text)"; done
echo "== Ex4: what happened when a new source version was written =="
docker logs --since 2026-11-09T04:51:48Z --until 2026-11-09T04:52:21Z floci 2>&1 | grep EventBridgeInvoker | sed 's/^[0-9-]* //; s/,[0-9]* WARN .*EventBridgeInvoker\] / WARN /; s/^/  /'
echo "  pipeline executions now: $(aws codepipeline list-pipeline-executions --pipeline-name usms-enrolment-pipeline --query 'length(pipelineExecutionSummaries)' --output text)  (5 before the upload)"
echo "== Ex5: artifact usms-enrolment-build-22.zip, downloaded =="
aws s3api get-object --bucket usms-pipeline-artifacts --key usms-enrolment-build-22.zip $D/a.zip >/dev/null
echo "  root of the zip: $(unzip -Z1 $D/a.zip | tr '\n' ' ')"
unzip -p $D/a.zip imagedefinitions.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  imagedefinitions.json: %s, %d entry: %s" % (type(d).__name__, len(d), json.dumps(d)))'
echo "== Ex5: smoke tests, local build of the same tree =="
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app 2>&1 | sed -n '/== smoke tests ==/,/smoke tests failed/p' | sed 's/^/  /'
echo "== Ex5: outputs/lab-11-lab08b-readiness.txt (what Lab 12 Step 1 prints) =="
sed -n '1,8p' outputs/lab-11-lab08b-readiness.txt | sed 's/^/  /'
rm -rf $D
