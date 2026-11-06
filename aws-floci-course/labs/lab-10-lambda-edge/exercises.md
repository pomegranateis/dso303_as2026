# Lab 10 - Independent Lab Exercises

Environment: Floci v1.5.34. Lambda runs real code in containers (`public.ecr.aws/lambda/nodejs:20`, `python:3.12`), S3 event delivery works, and CloudFront stores a distribution record. Floci evaluates no IAM or resource policy, and on this build it runs `$LATEST` whatever qualifier is named.

Labels: **Observed** (seen in command output), **Conceptual** (reasoned, not run), **Floci limitation** (behaves differently from real AWS). Full output is in [`evidence/`](evidence/).

---

## Exercise 1 - Basic: extend the security header set

([evidence/lab-10-ex1.txt](evidence/lab-10-ex1.txt))

- **The change is one line of data** in `SECURITY_HEADERS`: `'content-security-policy': { key: 'Content-Security-Policy', value: "default-src 'self'" }`. There's no second block of code.
- **Deployment:** `node --check`, rebuilt the archive from inside the function's directory, `update-function-code`, then **published version 2**.
- **Version 1 was not deleted or overwritten.** `list-versions-by-function` shows `$LATEST`, 1 and 2.
- **`templates/lab-10-distribution-config.json` named `usms-edge-origin-response:2`.** It was valid JSON and still version-qualified; verify stayed at 51/0. Exercise 2 later moved it on to `:3`.

**Expected vs observed:**
- **`$LATEST`:** 5 security headers, as expected.
- **`--qualifier 1`:** also returns 5, where the lab expects 4. **Floci limitation:** `invoke --qualifier N` reports `ExecutedVersion: $LATEST` for every N. Floci runs the newest code whatever version you name.
- **Downloading each version's code doesn't help:** `get-function --qualifier 1` and `--qualifier 2` return the same `Code.Location`, a single snapshot per function that already contains the CSP line.
- **The only trace of version 1's own code** is the `CodeSize` recorded when it was published: **1092 bytes for v1, 1124 for v2** (the extra 32 bytes are the CSP line).

So on this build a "version" is metadata, not an immutable copy of the code. On real AWS, `--qualifier 1` would run the frozen four-header code. That immutability is the whole reason Lambda@Edge insists on version-qualified ARNs, and it's the one property this lab can't demonstrate.

---

## Exercise 2 - Intermediate: a dedicated edge execution role

([evidence/lab-10-ex2.txt](evidence/lab-10-ex2.txt))

**`policies/usms-edge-basic-policy.json` → `USMSEdgeBasic`** grants log writes only, with no S3 and no other service, on two resource patterns:
- `arn:aws:logs:us-east-1:<acct>:log-group:/aws/lambda/usms-edge-*` and its `:*` (streams), for direct invocations in the home region;
- `arn:aws:logs:*:<acct>:log-group:/aws/lambda/us-east-1.usms-edge-*` and its `:*`. On real AWS an edge replica logs to a group named `/aws/lambda/us-east-1.<function>` **in the region nearest the viewer**, so a policy scoped to the home region would leave every edge invocation unable to log. The region is a wildcard there; the name is still `usms-edge-*`, never `*`.

**`usms-edge-exec-role`** reuses `policies/trust-lambda-edge.json` unchanged (lambda with the Lab 09 conditions, plus edgelambda). Nothing was modified or detached on `usms-lambda-exec-role`, and the notifier still uses it.

Both edge functions were repointed with `update-function-configuration --role` and **published as new versions** (viewer 2, origin 3).

The simulator confirms the new role's scope:

| Action | Resource | Decision |
|---|---|---|
| `logs:PutLogEvents` | `/aws/lambda/usms-edge-viewer-request` (us-east-1) | allowed |
| `logs:PutLogEvents` | `/aws/lambda/us-east-1.usms-edge-viewer-request` (eu-west-1) | allowed |
| `logs:PutLogEvents` | `/aws/lambda/usms-transcript-notifier` | implicitDeny |
| `s3:GetObject` | `usms-student-data/transcripts/x.json` | implicitDeny |

**What happened to version 1's role.** `list-versions-by-function` shows version 1 of both functions still naming `usms-lambda-exec-role`; only the new versions name `usms-edge-exec-role`. (`get-function-configuration --qualifier 1` can't show this here, because it ignores the qualifier.)

A published version freezes its configuration, and the execution role is part of the configuration, so `update-function-configuration` changes `$LATEST` and nothing that was already published. **Rolling back to version 1 therefore also rolls back to the old role**, the one that can read the transcripts bucket. A rollback is a security change as well as a code change, and any version that should never run again has to be deleted, not just left unreferenced.

**Follow-ups:**
- The distribution config now associates **viewer `:2` and origin `:3`**, the least-privilege versions, and `configs/lab-10.env` records them.
- The new role's edge principal is in `configs/usms-iam-accepted-findings.json`. The Lab 09 audit reports `HIGH=0 ACCEPTED=5 roles=11`.

**Conceptual:** deploying these functions as `usms-deploy-role` would need `iam:PassRole` on `usms-edge-exec-role` to `lambda.amazonaws.com`. Lab 09's `USMSDeployBase` allows passing only three ECS roles to `ecs-tasks`, so that's a deliberate gap to close before a pipeline can deploy edge code.

---

## Exercise 3 - Problem solving: an edge-readiness report

`scripts/utilities/usms-edge-report.sh` ([evidence/lab-10-ex3.txt](evidence/lab-10-ex3.txt)):

- **No hard-coded list:** one `list-functions` call filtered with `starts_with(FunctionName, 'usms-')`, then per-function version and alias counts.
- **JSON built in `python3`,** printed on stdout and nothing else. Diagnostics ("reading <fn>") go to stderr, and `| python3 -m json.tool` accepts stdout.
- **Runs from any directory:** `REPO_ROOT` comes from `${BASH_SOURCE[0]}`. The output from `~` and from `labs/` was identical.
- **Safe under `set -u`:** environment and VPC are read with `.get()` at every level, so a function with no `Environment` key is just "no variables".
- **Explains every `false`:** each object adds `not_eligible_because`.

**Observed:** the two edge functions are `edge_eligible: true`. **`usms-transcript-notifier` is `false`, for one reason: "2 environment variables".**

**On "two independent reasons":** under the exercise's own rule, the notifier's 256 MB and 30 s are within the non-viewer caps (10240 MB and 30 s), so there's only one reason. It fails for a second reason only if the viewer caps are applied to every function, which is what Step 14's `edge_eligibility` helper does (timeout ≤ 5 regardless of trigger). I kept the exercise's rule and report one reason rather than bend the script to match the expected text.

---

## Exercise 4 - Challenge: design the transcript delivery policy

[`notes/lab-10-edge-design.md`](../../notes/lab-10-edge-design.md):

- **Where each piece of logic runs.** URI normalisation in a CloudFront Function. The token check at viewer-request, in a CloudFront Function if the token is HMAC-signed (to verify), otherwise Lambda@Edge, with CloudFront signed cookies as the no-code option to evaluate first. Security headers move to a response headers policy. Invalidation on correction is regional.
- **The cache key** is the normalised URI only. That's safe *because* the per-student check runs before the cache.
- **Five-minute corrections without re-fetching:** `max-age=300, s-maxage=86400` plus a one-path invalidation on correction, with ETag revalidation as the alternative.
- **The refusal report** comes from centralised CloudFront logs, not edge function logs, which land in the region nearest each viewer.
- **Origin outages:** an origin group plus `stale-if-error`.
- **The wrong tool for the edge:** the Dean's report.
- **What to measure first:** the transcript cache hit ratio.

---

## Exercise 5 - Integration: hand the S3 lab a bucket it can start from

([evidence/lab-10-ex5.txt](evidence/lab-10-ex5.txt))

- **The draft:** `outputs/lab-09-bucket-policy-draft.json` exists (Lab 09 Exercise 5), so no equivalent was generated. The script's generation branch exists for when it's missing.
- **Validation.** `scripts/utilities/usms-s3-readiness.sh` checks each principal with `get-role` (the account root always resolves), and each resource against the real bucket with `head-bucket`. Result: **every ARN resolves** (five role principals, the account root, the bucket with and without `/*`).
- **Negative test:** the same script on a copy with a non-existent role and a misspelled bucket reported **3 MISMATCH(ES)** and named each one. It fixed nothing, and left the real readiness file alone.
- **Not applied:** `get-bucket-policy` fails with **NoSuchBucketPolicy**, which is correct.
- **The trace:** `outputs/lab-10-edge-trace.json` (the allow trace, a three-stage chain) was uploaded to `transcripts/evidence/lab-10-edge-trace.json`. **The notifier saw it**, with a `USMS_NOTIFY` line for that key and `readable: true`.
- **`outputs/lab-10-s3-readiness.txt`** is generated by the script, not by hand. It covers the bucket name and ARN, 5 objects under `transcripts/`, the notification (id, `:live` ARN, `prefix=transcripts/,suffix=.json`), the three functions and their versions, CloudFront support (with the association caveat), the bucket-policy state, and the validation result. Running it twice gives identical output apart from the timestamp. `git check-ignore -v` names `.gitignore:7:outputs/*` for both the readiness file and the draft.

---

## Floci limitations found in the exercises

| Limitation | Seen in | Real AWS |
|---|---|---|
| `invoke --qualifier N` runs `$LATEST` | Ex 1 | Runs version N's frozen code |
| One code snapshot per function; `get-function --qualifier` ignored | Ex 1 | Each version keeps its own code forever |
| `get-function-configuration --qualifier` ignored | Ex 2 | Returns that version's configuration |
| Per-version Role kept correctly in `list-versions-by-function` | Ex 2 | Same (this part is modelled) |
| No policy is evaluated on calls; the simulator was used to judge the new role | Ex 2 | Enforced |
