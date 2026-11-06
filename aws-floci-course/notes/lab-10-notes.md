# Lab 10 notes

## Support (Step 4, outputs/lab-10-support-probe.txt)
Floci server 1.5.34. Lambda, layers, S3, CloudWatch Logs, CloudFront and IAM all answer, so Step 15 took Path A.
- The first probe run reported everything UNSUPPORTED. That was my mistake: I sourced course.env inside `{ ...; } | tee`, a subshell, so the probe ran without the Floci profile. Re-run correctly.
- "SUPPORTED" for CloudFront only meant exit 0: list-distributions answers with an XML root of `<ListDistributionsResult>` instead of `<DistributionList>`, and the CLI parses that to nothing (Step 23).
- get-role refuses the ARN that configs/lab-01.env stores in USMS_ROLE_LAMBDA; every use takes `${USMS_ROLE_LAMBDA##*/}`.

## Environment
- The host had rebooted 9 minutes before the lab. The EKS cluster (Labs 07-08) is down and was left down: this lab does not use it.
- No Lambda runtime images were cached. Floci pulled `public.ecr.aws/lambda/nodejs:20` at the first invoke (17 s) and `public.ecr.aws/lambda/python:3.12` at the first notifier run (about 3.5 minutes on this connection); neither timed out.
- Node v22 is installed locally, so `node --check` checked both handlers before deployment.

## Step 5: the bucket
usms-student-data created, tagged Project/Tier/Lab=10 (the lab's Lab=06 is a copy-paste slip; the same for the function tags). head-bucket exits 0 for the first time in the course. The simulator now shows real decisions on a real ARN: usms-ec2-app-role, usms-ecs-task-role and usms-eks-node-role may Get and Put; usms-transcripts-reader-role Get only (Put explicitDeny); usms-lambda-exec-role Get only (via USMSLambdaBasic).

## Step 6: the trust policy - a deliberate deviation
The lab's trust document lists lambda and edgelambda in one unconditioned statement. update-assume-role-policy replaces the whole document, so applying it as written would have removed the aws:SourceAccount and aws:SourceArn conditions Lab 09 Exercise 2 put on usms-lambda-exec-role. policies/trust-lambda-edge.json has two statements instead: lambda.amazonaws.com keeps its Lab 09 conditions; edgelambda.amazonaws.com is unconditioned, because which source keys CloudFront's replication sends is not verified and a condition on a key that is never sent would stop every edge function. The edge principal is recorded in configs/usms-iam-accepted-findings.json; the Lab 09 IAM audit reports it as ACCEPTED (HIGH=0).
The lab's verify, length(Statement[0].Principal.Service), would read the length of a string with two statements; length(Statement[].Principal.Service) = 2 is the equivalent check. Undo saved in outputs/lab-10-lambda-exec-role-trust-before.json.

## Steps 7 to 9: the viewer-request function
Quoted heredoc; the template literal survived (grep shows ${studentId.toLowerCase()}). Archive holds index.mjs at its root. Function Active: nodejs20.x, 128 MB, 5 s, $LATEST.
Allow event: Status 200, Error None, uri /transcripts/2026/stu-00417.json, x-usms-edge viewer-request-allow;student=stu-00417. Deny event (your turn): Status 200, Error None - the function made a decision - and a RESPONSE object: status 403, statusDescription, x-usms-edge viewer-request-deny, JSON body, no uri anywhere.

## Step 10: logs
invoke --log-type Tail returns no LogResult key at all on this build. `--query LogResult --output text` prints None, and openssl base64 -d turns those four letters into garbage bytes. The log group and one stream exist but hold no START/END/REPORT events. Returned payloads are the evidence, as the lab's limitation allows. (The notifier's application output does reach CloudWatch Logs - Step 21.)

## Steps 11 to 13
Version 1 of each edge function; the qualified-ARN grep accepts :1 and rejects the unqualified ARN. Origin-response: the origin's content-type, etag and server survive; four security headers and cache-control are added; x-usms-edge-chain reads viewer-request-allow;student=stu-00417;origin-response.

## Step 14: edge restrictions
Environment variables set on $LATEST and removed. Both functions edge-eligible (0 NO lines). Negative test: with one variable set, the eligibility check printed "NO 1 environment variables set", so it can fail.
Correction (found in Step 18): "version 1 never had them: None" was answered by get-function-configuration --qualifier 1, which ignores the qualifier on this build - that was $LATEST's answer, not evidence about version 1.

## Step 15: CloudFront - Path A, only half real
create-distribution returned E1OWPB9TTQNP7G (Deployed). The stored DefaultCacheBehavior has LambdaFunctionAssociations Quantity 0, no ForwardedValues or TTLs, and AllowedMethods with CachedMethods merged in (GET, HEAD, GET, HEAD). The record proves nothing about the associations, so the Path B structural validation was run on the config as well: 11 ok, no errors. templates/lab-10-distribution-config.json is the source of truth, and it is what verify-lab-10.sh reads.

## Step 16: the edge simulator
Allow: three stages, 200, five headers added, the chain marker composed. Deny: a chain of one, 403, origin never contacted. The script also runs from ~ (REPO_ROOT from BASH_SOURCE). Allow trace restored for Exercise 5.

## Steps 17 to 19: the notifier
python3.12, notifier.handler, 256 MB, 30 s, environment variables (legal here). Version 1, alias live -> 1. Your turn: version 2 published, live -> 2 -> 1; versions $LATEST, 1, 2 throughout.
Floci: get-function-configuration ignores --qualifier (live, 1, $LATEST all report Version $LATEST and the unqualified ARN).
Step 19: add-permission with --qualifier live --source-arn --source-account. Floci stored only the ArnLike AWS:SourceArn condition - the SourceAccount condition is DROPPED - and stored the statement on the unqualified function (Resource without :live). The lab's assertion only checks that the bucket name appears, so it prints "scoped to one bucket in one account" while the account half is missing.

## Steps 20 and 21: delivery works
put-bucket-notification-configuration with the :live ARN, prefix transcripts/ and suffix .json. Uploading outputs/lab-08-scaling-evidence.json made Floci launch the notifier at once - S3 event delivery WORKS on this build. filter-log-events found: USMS_NOTIFY {... "key": "transcripts/evidence/lab-08-scaling-evidence.json", "readable": true, "size": 3128} - and readable: true means boto3 inside the container reached Floci's S3.
Fallback run anyway: the synthetic event returned processed 1 with read_error ClientError (the object does not exist), as the lab predicts.
invoke --qualifier live reports ExecutedVersion $LATEST, and the log stream is [$LATEST]: Floci records versions and aliases but always runs $LATEST.
Your turn: notes/ignore-me.json and transcripts/evidence/ignore-me.txt produced no notifier run at all - the container log shows exactly three runs (the real upload, the synthetic probe, a control upload that did match), and no "skipping" line, so S3's filter excluded both before any invocation, not the handler. The control upload fired at once, so the silence was the filter, not a dead trigger.

## Step 22: persistence
Inventory before and after floci-down/up identical: IDENTICAL. The stronger checks after the restart: the edge chain still composes, and a new upload still fired the notifier (after-restart.json, readable). The Lab 3 instances were started again.

## Step 23: configs/lab-10.env
25 exports, all populated, sources cleanly. The two CloudFront values came out not-created because of the list-distributions XML root bug; they are taken from the create-distribution response and confirmed with get-distribution, with the reason in the file. After Exercises 1 and 2 the edge versions are viewer :2 and origin :3, and USMS_EDGE_ROLE_ARN is usms-edge-exec-role.

## Section 8
verify-lab-10.sh as given: PASS=46 FAIL=5 - four role checks (USMS_ROLE_LAMBDA is an ARN here; get-role refuses it) and the outputs/.gitkeep false positive. Two script fixes: PASS=51 FAIL=0. The cleanup script passes bash -n and has not been run.
The verifier's "scoped to this bucket" check passes although Floci dropped the SourceAccount condition: it checks for the bucket name only. A stricter check would look for SourceAccount too, and would fail here.

## Versions on Floci are metadata only (Exercise 1)
get-function --qualifier N returns the same Code.Location for every version - one code snapshot per function, already containing the newest code - and invoke --qualifier N runs $LATEST. Only CodeSize, recorded at publish time, differs (v1 1092, v2 1124 bytes). The immutability that makes Lambda@Edge safe, and that Step 11 explains, cannot be demonstrated on this build at all.

## Review questions (Section 14)

1. Moving the whole enrolment API to Lambda@Edge "because it will be faster for everyone". The two strongest arguments against: first, enrolment is a write path that has to reach its data - the database, the queue, the task role's S3 bucket - which lives in one region; an edge function in Thimphu's nearest location still crosses to us-east-1 for every write, so the user waits for the same round trip plus an extra hop, and every AWS call the function makes "crosses a continent" (Step 17). Second, the edge's constraints fit badly: no environment variables, no VPC access to the database, Node or Python only, 5 or 30 second caps, logs scattered across regions, and replication that makes every deploy and rollback take minutes. They would be right for the read-mostly, cacheable or reject-early part: serving static pages, rejecting unauthenticated requests before they reach the origin, or a response that can be computed from the request alone - where the edge saves the whole round trip.

2. CloudFront Functions run JavaScript (cloudfront-js-2.0) only, at viewer-request and viewer-response only, with sub-millisecond limits, no network or file access and no body access; they cost roughly a sixth of Lambda@Edge per invocation and have no duration charge. Lambda@Edge runs Node.js or Python at all four trigger points, may call the network, has 5 s (viewer) or 30 s (origin) limits, can read the body when IncludeBody is set, and is billed per request plus duration. Appending /index.html to a URI: a CloudFront Function - pure string work on every request, where cost and latency matter most. Checking a JWT signature: a CloudFront Function if the algorithm is HMAC and its crypto module covers it (to verify), otherwise Lambda@Edge at viewer-request. Fetching a per-user redirect from DynamoDB: Lambda@Edge, at origin-request if it can be cached or viewer-request if not, because it needs a network call, which CloudFront Functions cannot make.

3. Origin-response runs after the origin answers and before the object enters the cache, so the headers it adds are stored with the cached object: the function runs once per cache miss, and every cache hit serves the stored headers for free. Viewer-response runs on every response to every viewer, cache hits included, so the same output costs one invocation per request - at a high hit rate, orders of magnitude more invocations. Viewer-response is forced when the header depends on the individual viewer or request rather than the object: a per-request nonce for a Content-Security-Policy, a header that echoes the viewer's country, or a Set-Cookie per session. Caching any of those would serve one viewer's value to everyone.

4. They answer different questions for different callers. The resource policy (lambda add-permission) governs the call INTO the function: S3, acting as s3.amazonaws.com, calls lambda:InvokeFunction on usms-transcript-notifier:live, and Lambda checks the function's resource policy. The execution role governs the calls OUT of the function: once running, the notifier's code calls s3:HeadObject/GetObject as usms-lambda-exec-role, and S3 checks the role's identity policy (USMSLambdaBasic). Delete the resource-policy statement and S3 can no longer invoke the function: uploads succeed, nothing runs, and nothing is logged because the function never started - the silent failure the lab warns about. Delete s3:GetObject from the role and the function still runs on every upload, but its head_object call is denied, so it reports readable: false with an AccessDenied error. Neither replaces the other.

5. Without --source-arn and --source-account, the statement lets s3.amazonaws.com invoke the function on behalf of any bucket in any account. An attacker who knows the function ARN creates a bucket in their own account, configures a notification targeting usms-transcript-notifier:live, and uploads objects with crafted keys: S3 - a trusted service, the "deputy" - invokes our function for them, running our code with our execution role (and our bill), with input they control. --source-arn pins the bucket; --source-account pins the owning account, which matters because bucket names are global and can be re-registered by someone else after deletion. The Lab 09 equivalent is the aws:SourceAccount and aws:SourceArn conditions on usms-ecs-task-role's trust policy. They are the same idea: when a service principal acts, the policy names not only the service but whose resource it is acting for. Here Floci dropped the SourceAccount half, which only reading the stored policy revealed.

6. Validation happens at CloudFront, when the function version is associated with a distribution (create-distribution or update-distribution): CloudFront checks the region, that the ARN is version-qualified, that there are no environment variables, and the caps for the trigger point. update-function-configuration is not rejected because environment variables are a legal Lambda feature - Lambda does not know the function is meant for the edge; the restriction belongs to a different service, in a different call, about a different resource, minutes later. So edge configuration has to be checked on its own terms before the association - statically, as Step 14's eligibility check and verify-lab-10.sh do - because the API that accepted the setting is not the one that will judge it. It is the course's rule in its plainest form: the command succeeding only proved Lambda stored what I sent, not that it is valid for what I meant. This lab produced more of the same: create-distribution succeeded and stored no associations; add-permission succeeded and stored no account condition; publish-version succeeded and froze no code.
