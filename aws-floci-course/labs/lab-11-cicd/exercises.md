# Lab 11 - Independent Lab Exercises

Environment: Floci v1.5.34, Path A. CodeBuild runs real containers (`python:3.12-slim`, the Known Issues alternative), but only when the buildspec is passed inline: Floci reads a project's `buildspec` field as YAML text, never as a path inside the source. It ignores `finally`, and it uploads standalone artifacts to the bucket root as `<project>-<build#>.zip`. CodePipeline records which source version each execution took, but its builds run no commands and it writes no BuildOutput. No IAM, trust or resource policy is evaluated; the simulator judges the policies.

Labels: **Observed** (seen in command output), **Conceptual** (reasoned, not run), **Floci limitation** (behaves differently from real AWS). Full output is in [`evidence/`](evidence/). Screenshots: `img/lab11-06-exercises-1-3.png` and `img/lab11-07-exercises-4-5.png`.

---

## Exercise 1 - Basic: a second build project for the results service

([evidence/lab-11-ex1-template.txt](evidence/lab-11-ex1-template.txt), [lab-11-ex1-project.txt](evidence/lab-11-ex1-project.txt), [lab-11-ex1-builds.txt](evidence/lab-11-ex1-builds.txt), [lab-11-ex1-artifacts.txt](evidence/lab-11-ex1-artifacts.txt))

- **Source tree:** `labs/lab-11-cicd/app-results/` has `VERSION` (`r1`), `src/index.html` (with `__RELEASE__`/`__BUILT_AT__`) and a four-phase `buildspec.yml`. That buildspec writes `build-metadata.json` with `"service": "results"`, and its base-directory is `dist`.
  - The local runner passes it (exit 0).
  - Its `dist/` is git-ignored (`.gitignore:38`).
- **The template:** `templates/lab-11-results-build-project.json` was made from Step 10's template with `sed`, so the diff is exactly five lines:
  - name, description, `source.location` (`source/usms-results-src.zip`) and `artifacts.name`: the four fields the hint names;
  - `USMS_SERVICE=results`, so the project doesn't claim to be the enrolment service.
  - It has 0 unexpanded `$`.
- **One role:** `usms-results-build` runs as `usms-codebuild-role`. `list-roles` shows no second CodeBuild role. Its image got the same Known Issues switch as the enrolment project, with both env vars kept.

**Does `USMSCodeBuildBase` already permit it? Yes**, because:
- **S3:** its S3 statement covers the whole artifact bucket, so the results source and its artifacts are inside it.
- **Logs:** the template keeps `logsConfig` on `/aws/codebuild/usms-enrolment-build`, a group its log statement names.

The simulator shows the boundary:

| Action | Resource | Decision |
|---|---|---|
| `s3:GetObject`, `s3:GetObjectVersion` | `usms-pipeline-artifacts/source/usms-results-src.zip` | allowed |
| `s3:PutObject` | `usms-pipeline-artifacts/build/usms-results-build.zip` | allowed |
| `logs:PutLogEvents` | `/aws/codebuild/usms-enrolment-build` (the shared group) | allowed |
| `logs:PutLogEvents` | `/aws/codebuild/usms-results-build` (a group of its own) | implicitDeny |

**Not versioning the policy.** The tidier design gives each project its own log group and adds that group to the policy. I didn't, because Lab 12 Step 12 creates `USMSCodeBuildBase` v2 from a fixed document, and its verify checks that the default version is `v2`. A v2 created now would become v3 there. The shared log group is the cost.

**Builds, Observed:**
- **Build 1** (plain `start-build`): SUCCEEDED having run nothing. **Floci limitation:** the `buildspec` field `buildspec.yml` is parsed as YAML, a bare string with no phases.
- **Build 2** (the same buildspec passed inline): SUCCEEDED.
- **The artifact:** Floci uploaded it as **`usms-results-build-2.zip` at the bucket root**. It ignored `artifacts.path` (`build`) and `artifacts.name`; real AWS would write `build/usms-results-build.zip`.
- **The artifact's own `build-metadata.json`:** `"service": "results"`, `"release": "r1"`, `"buildId": "usms-results-build:2"`. It can't be mistaken for an enrolment artifact (`"service": "enrolment"`, `usms-enrolment-build:N`).
- **`sourceVersion` is `local`:** **Floci limitation**, it never sets `CODEBUILD_RESOLVED_SOURCE_VERSION`.

---

## Exercise 2 - Intermediate: a finally block and a build report

([evidence/lab-11-ex2-local.txt](evidence/lab-11-ex2-local.txt), [lab-11-ex2-finally-probe.txt](evidence/lab-11-ex2-finally-probe.txt), [lab-11-ex2-floci.txt](evidence/lab-11-ex2-floci.txt), [lab-11-ex5-ex2-artifacts.txt](evidence/lab-11-ex5-ex2-artifacts.txt))

**The change.** `post_build` now:
- writes `not-run` to `/tmp/usms-smoke-exit`;
- runs `rc=0; bash tests/smoke.sh || rc=$?` and records `rc`;
- fails the phase if `rc` is not 0.

A `finally:` block, a sibling of `commands:`, then writes one line to `dist/build-summary.txt`:

```
release=r5 tests=failed smoke_exit=1 build=<CODEBUILD_BUILD_ID or local> finishedAt=<UTC>
```

Design choices:
- **The `|| rc=$?` form** behaves the same in the runner's `set -Eeuo pipefail` shell and in a shell without `-e`.
- **The status file is in `/tmp`, not the app directory,** because `usms-pack-source.sh` excludes only `*.bak` and `dist/*` and would have shipped it in the source zip.
- **The `finally` block doesn't rescue the phase.** A failed smoke test still fails the build, and `finally` only runs.

**How I tested it, and what that means for the claim.** The lab's runner reads only `commands` from each phase, so it skips `finally` silently. A local pass says nothing about the summary:

| Test | Result |
|---|---|
| Runner alone, intact tree | exit 0, `build-summary.txt` **absent** |
| Runner + the `finally` commands extracted from the YAML and run in the same directory, intact tree | `release=r5 tests=passed smoke_exit=0` |
| The same, on a copy whose `healthz.html` says `degraded` | runner exit 1 (`FAIL health endpoint says ok`), then `release=r5 tests=failed smoke_exit=1` |

I then asked whether Floci runs `finally` (**Observed**):

| Floci probe | Expected on real AWS | Floci |
|---|---|---|
| A: commands ok, `finally` exits 3 | phase FAILED (a failing `finally` command fails the phase) | **SUCCEEDED** |
| B: commands `exit 1`, `finally` echoes `finally-ran` and exits 3 | context includes the `finally` output | `Exit code 1: commands-ran`, no `finally` output |
| Build 23: the real buildspec on the broken-health-page zip, S3 artifacts | artifact contains `build-summary.txt` saying `tests=failed` | FAILED in POST_BUILD; **the artifact was uploaded, with 0 `build-summary.txt` entries** |

**Floci limitation:** `finally` is not executed. The claim is therefore narrower than "CodeBuild produced the summary":
- the `finally` commands produce the right summary after both a pass and a failure (tested by emulation);
- CodeBuild runs `finally` after a failed command (the buildspec reference: "The commands in a `finally` block are run even if a command in the `commands` block fails");
- the AWS docs also say "the UPLOAD_ARTIFACTS phase is always attempted, even if the BUILD phase fails".

The end-to-end outcome (an artifact containing a failed summary) is Conceptual here. Build 23 did show the other half for real: a build that failed in post_build still uploaded its artifact.

---

## Exercise 3 - Problem solving: make the configuration check robust

([evidence/lab-11-ex3-matrix.txt](evidence/lab-11-ex3-matrix.txt), [lab-11-ex3-trust.txt](evidence/lab-11-ex3-trust.txt))

**The check.** Both pre_build greps (the container check and my Step 19 port check) are replaced by one standard-library `python3` block, in a quoted `<< 'CHECK'` heredoc so the program reaches the interpreter as written. It loads `config/service.json`, compares the values, and exits with a message naming expected and found:

```
config/service.json names the wrong container: expected "enrolment-api", found "enrolment-api-v2"
config/service.json: "port" must be 80 - the port enrolment-api listens on and the target group checks - found 8080
```

The seventh smoke assertion had the same whitespace dependence. It now parses the JSON too, and keeps its label, because Lab 12 Step 14 inserts its own assertion after that exact line.

**Five shapes of `service.json`, through the local runner** (**Observed**):

| Shape | Old container grep | Old port grep | New build |
|---|---|---|---|
| `indent=2` (as committed) | pass | pass | pass |
| `indent=4` (the lab's test) | pass | pass | pass |
| compact, `separators=(",",":")` | **FAIL** | **FAIL** | pass |
| `indent=4`, container wrong | FAIL | pass | FAIL, names both values |
| `indent=4`, port 8080 | pass | FAIL | FAIL, names both values |

**The lab's own proof doesn't break the old grep.** `json.dump` keeps the `": "` separator whatever the indent, so four-space indentation passes both the old and the new check. Compact JSON is what exposes the dependence: two valid files the old greps reject.

**The trust policy.** `policies/trust-codebuild.json` now has two conditions:
- `StringEquals aws:SourceAccount 000000000000`;
- `ArnLike aws:SourceArn` listing **both** project ARNs. Exercise 1 reuses this role, and naming only the enrolment project would lock the results build out on real AWS.

Applied with `update-assume-role-policy`. IAM's readback matches, and both ARNs equal the live project ARNs exactly. **Floci limitation:** stored, not evaluated. The attack this closes is explained in [`notes/lab-11-notes.md`](../../notes/lab-11-notes.md) (Exercise notes): another project in the *same* account running as this role.

---

## Exercise 4 - Challenge: trigger the pipeline without polling

([evidence/lab-11-ex4-pattern.txt](evidence/lab-11-ex4-pattern.txt), [lab-11-ex4-create.txt](evidence/lab-11-ex4-create.txt), [lab-11-ex4-live.txt](evidence/lab-11-ex4-live.txt))

**Design.**
- **Delivery:** the bucket sends its own events to EventBridge (`put-bucket-notification-configuration` with `EventBridgeConfiguration {}`).
- **The rule:** `usms-enrolment-source-changed` matches one object, not the bucket ([`templates/lab-11-source-trigger-rule.json`](../../templates/lab-11-source-trigger-rule.json)):

  ```json
  { "source": ["aws.s3"], "detail-type": ["Object Created"],
    "detail": { "bucket": { "name": ["usms-pipeline-artifacts"] },
                "object": { "key": ["source/usms-enrolment-src.zip"] } } }
  ```

- **The target** ([`templates/lab-11-source-trigger-targets.json`](../../templates/lab-11-source-trigger-targets.json)) is the pipeline ARN with `RoleArn` `usms-events-pipeline-role`.
- **No polling anywhere:** `PollForSourceChanges` stays `"false"`.

**The two delivery routes, and the CloudTrail dependency.** A PutObject on a versioned object can reach EventBridge two ways, with different `detail-type`s:
- **S3's own EventBridge delivery** (`Object Created`, with `detail.object.version-id`) needs only the bucket setting above.
- **CloudTrail** (`AWS API Call via CloudTrail`, `eventName` `PutObject`, `requestParameters.bucketName/key`) is the route older CodePipeline guidance used. PutObject is an S3 *data* event, and trails don't log data events by default.
  - Without a trail with a data-event selector on this bucket or key, no event is ever produced.
  - The rule never matches and nothing reports an error.
  - It also costs a trail and data-event charges.
- I kept the CloudTrail pattern for comparison ([`templates/lab-11-source-trigger-rule-cloudtrail.json`](../../templates/lab-11-source-trigger-rule-cloudtrail.json)), validated but not created.

`test-event-pattern` on Floci (**Observed**) shows each rule matches only its own detail-type, and only the one key:

| Sample event | S3-native rule | CloudTrail rule |
|---|---|---|
| Object Created, `source/usms-enrolment-src.zip` | True | False |
| Object Created, `source/usms-results-src.zip` | False | False |
| CloudTrail PutObject, `source/usms-enrolment-src.zip` | False | True |
| CloudTrail PutObject, `source/usms-results-src.zip` | False | False |

**The target's role, and why it isn't the pipeline role.**
- **What EventBridge needs:** one permission, `codepipeline:StartPipelineExecution` on this pipeline's ARN (`USMSEventsStartPipeline`).
- **Its trust:** `usms-events-pipeline-role` trusts `events.amazonaws.com` with `aws:SourceAccount` and `aws:SourceArn` = this rule's ARN.
- **Why not the pipeline role:** that role trusts `codepipeline.amazonaws.com` and carries the artifact store, StartBuild and `iam:PassRole`. Reusing it would mean adding EventBridge to its trust, handing a service that only needs to *start* the pipeline the power to read and write every artifact and pass the build role.
- **Simulator:** StartPipelineExecution on this pipeline allowed; on another pipeline, UpdatePipeline, or PassRole on the pipeline role: implicitDeny.
- **Audit:** the Lab 09 audit, run on a refreshed inventory, sees 14 roles with **HIGH=0**. The new role has only the usual MED (no permissions boundary).

**What ran and what didn't** (Observed):

| Hop | Result on Floci |
|---|---|
| `put-rule`, `put-targets`, `describe-rule` | created; pattern stored exactly |
| Target `RoleArn` | **not stored**: `list-targets-by-rule` returns `None` |
| `EventBridgeConfiguration {}` on the bucket | accepted; `get-bucket-notification-configuration` reads back **empty** |
| New version of `source/usms-enrolment-src.zip` → EventBridge | **delivered and matched**: Floci's `EventBridgeInvoker` acted within a second of the upload (04:51:48) |
| EventBridge → CodePipeline | **failed**: `WARN EventBridge: unsupported target ARN type: arn:aws:codepipeline:us-east-1:000000000000:usms-enrolment-pipeline`; executions 5 before, 5 after |
| New version of `source/usms-results-src.zip` | no invoker line: the rule matches one key |
| CloudTrail | `describe-trails` answers, with no trails; the data-event route was not built |

So the S3 → EventBridge → rule half is demonstrated. The rule → CodePipeline half is not, and the precise reason is that Floci's EventBridge has no CodePipeline target. One thing I couldn't isolate: the bucket setting reads back empty, so whether Floci delivers S3 events regardless of it is unknown. On real AWS, without it, nothing is delivered.

---

## Exercise 5 - Integration: prepare the deployment contract for Lab 12

([evidence/lab-11-ex5-local.txt](evidence/lab-11-ex5-local.txt), [lab-11-ex5-floci.txt](evidence/lab-11-ex5-floci.txt), [lab-11-ex5-ex2-artifacts.txt](evidence/lab-11-ex5-ex2-artifacts.txt), [lab-11-lab08b-readiness.txt](evidence/lab-11-lab08b-readiness.txt))

**The build phase** now ends with:

```yaml
      - |
        IMAGE_URI="${IMAGE_URI:-public.ecr.aws/nginx/nginx:stable-alpine}" python3 - > "$ARTIFACT_DIR/imagedefinitions.json" << 'IMGDEF'
        import json, os
        cfg = json.load(open("config/service.json"))
        print(json.dumps([{"name": cfg["container"], "imageUri": os.environ["IMAGE_URI"]}], indent=2))
        IMGDEF
```

- **The container name** is read from `config/service.json`, not hard-coded.
- **The default image** is the one usms-enrolment-svc runs today (`public.ecr.aws/nginx/nginx:stable-alpine`, read from the live task definition).
- **It is always written as an array.** `IMAGE_URI` set in the environment wins. Tested with `registry.example.invalid/usms-enrolment:r5`, the same way a CodeBuild project variable would override it.

**The eighth smoke assertion**, `imagedefinitions.json is a one-element array`:
- It checks a list of length 1, a name equal to `config/service.json`'s container, and a non-empty `imageUri`.
- It rejected an object, two entries, an empty `imageUri` and a wrong name.
- Lab 12 Step 14's own insertion script, run against a copy, prints `already present - nothing to do`.

**Run the pipeline, download the artifact** (**Observed**):
- **Upload:** the updated source went up as version `33511987-9639-4bc6-a519-3b3797248fc8`.
- **The pipeline run:** execution `1968936b…` Succeeded and recorded that version. As everywhere in this lab, it wrote nothing under `usms-enrolment-pipeline/` (**Floci limitation**), so there is no pipeline artifact to download.
- **The closest real artifact:** I built the same uploaded source as a standalone build with S3 artifacts and the buildspec inline (build 22, SUCCEEDED), then downloaded `usms-enrolment-build-22.zip`. Its **root** holds `service.json healthz.html imagedefinitions.json index.html build-metadata.json`, and its `imagedefinitions.json` is `[{"name": "enrolment-api", "imageUri": "public.ecr.aws/nginx/nginx:stable-alpine"}]`. That is byte-identical to the local `dist/` copy.
- **What the container saw:** a diagnostic build (21) showed the same files and contents in the container's `dist/`.
- **Locally:** 8/8 smoke tests.

**The readiness file** `outputs/lab-11-lab08b-readiness.txt` is generated from live state, not typed:
- Its first lines have the shape Lab 12 Step 1 prints: `artifact: usms-enrolment-build-22.zip`, then `imagedefinitions.json:` and the JSON.
- After those come the provenance lines: source versionId, pipeline execution, the real-AWS key shape, and that the local copy is identical.
- It is git-ignored under `outputs/*`, as Lab 12 expects to find it there. A copy is in `evidence/`.

**Release label.** `VERSION` stays `r5`, because Lab 12 Step 8 sets `r6` itself and uses r6/r7 as image tags. This upload is therefore a second, different zip labelled r5, told apart only by its versionId. Review question 7 is about exactly that weakness.

**For Lab 12:** Step 14 replaces `buildspec.yml` wholesale (keeping this one as `buildspec.yml.lab08a`). The Exercise 2 `finally` block and the Exercise 3 JSON check will not carry over unless they're re-applied.

---

## Floci limitations found in the exercises

| Limitation | Seen in | Real AWS |
|---|---|---|
| Project `buildspec` field read as inline YAML; a path runs nothing | Ex 1 (build 1), Step 20 | Runs the file at that path in the source |
| Standalone artifacts written to `<bucket>/<project>-<build#>.zip`, ignoring `path` and `name` | Ex 1, Ex 5 | `build/usms-results-build.zip` |
| `CODEBUILD_RESOLVED_SOURCE_VERSION` unset (`sourceVersion: local`) | Ex 1, Ex 5 | The S3 object version |
| `finally` not executed | Ex 2 | Runs after `commands`, even after a failure |
| Trust conditions stored, not evaluated | Ex 3 | Evaluated on every AssumeRole |
| EventBridge cannot invoke a CodePipeline target; target `RoleArn` not stored | Ex 4 | Starts the pipeline as the target role |
| `get-bucket-notification-configuration` empty after `EventBridgeConfiguration` | Ex 4 | Returns `EventBridgeConfiguration: {}` |
| Pipeline executions write no BuildOutput | Ex 5 | An artifact per Build action |
