USMS_CICD_SUPPORT_PATH=A - Floci 1.5.34: CodeBuild, CodePipeline, ECR and CodeDeploy all answer (outputs/lab-11-support-probe.txt)

# Lab 11 notes

## Support and environment (Steps 1 to 4)
- Every earlier env file sourced. The deploy targets Lab 12 needs are all present: usms-ecs-cluster, usms-enrolment-svc, container enrolment-api, usms-enrolment-tg, usms-ecs-exec-role.
- Path A only means the APIs answer. Whether the services do what they say was judged by reading back state, as in every lab since 09.

## Steps 5 and 6: the artifact store
- usms-pipeline-artifacts: versioning Enabled, tags Project/Tier=pipeline/Lab=11, all four public-access blocks True.
- Two writes to probe/versioning.txt gave two versions, and the older one was still readable by its ID ("first"). Both versions were deleted by ID (0 left).
- My screenshot 1 shows only one version row, because I cut the table with `tail`. The live proof of versioning is the source key itself: 5 versions in screenshot 3.

## Steps 7 and 8: the source tree and the buildspec
- The buildspec was written with `<< 'BUILDSPEC'` (quoted), so `$USMS_RELEASE`, `$(date ...)` and `${CODEBUILD_BUILD_ID:-local}` reached the file unexpanded. The `<< META` inside it is unquoted, because it must expand at build time.
- **The rule:** a quoted delimiter writes the text; an unquoted one writes the result.
- **Your turn (port check):**
  - The obvious `grep -q '"port": 80'` also matches `"port": 8080`. I demonstrated that before using it.
  - The check I committed is anchored: `"port": 80,?[[:space:]]*$`.
  - With 8080 the local runner stopped in pre_build (exit 1) with a message naming the fix. With 80 restored it passed.

## Step 9: the build role
- usms-codebuild-role trusts codebuild.amazonaws.com with aws:SourceAccount. It has USMSCodeBuildBase attached (v1).
- **Simulator results:**
  - PutObject on the artifact store: allowed.
  - Its own log group: allowed. Another function's log group: implicitDeny.
  - GetObject on usms-student-data: explicitDeny.
- **The explicit Deny, in one sentence:** the build role runs whatever commands arrive in the source zip, so `BuildsDoNotTouchStudentRecords` denies all of S3 on the student-records bucket. A deny beats every allow, so no later policy version or extra attachment can quietly give build code those records.

## Step 10: the project
- Created from templates/lab-11-codebuild-project.json, which has 0 unexpanded `$` (unquoted heredoc, every value literal).
- Source S3, image aws/codebuild/standard:7.0, small, 15 minutes, logs in /aws/codebuild/usms-enrolment-build.

## Step 11: packing
- usms-pack-source.sh zipped the tree with buildspec.yml at the zip root: 9 entries, 0 under app/.
- Version r3 uploaded as 0398a32c-de5b-446f-8d38-3e21ea555d66.

## Step 12: the first build, and the known issue
- **Build 1: FAULT.** "pull access denied for aws/codebuild/standard" is the known issue (Known Issues, Lab 11). I diagnosed it from the phase context and Floci's log before switching.
- **The alternative from Known Issues:** `update-project --environment ... image=python:3.12-slim`.
  - `--environment` replaces the whole struct, so the shorthand form silently dropped USMS_PROJECT and USMS_SERVICE (Vars 0).
  - I re-applied it as JSON with both variables.
- **Build 2** SUCCEEDED on python:3.12-slim. A diagnostic build (3) whose inline buildspec could only fail FAILED in BUILD with "Exit code 1: about-to-fail". So builds are not simply rubber-stamped.

## Step 13: reading a build
- Eleven phase rows (the ten phases plus COMPLETED), every one SUCCEEDED in 0 seconds. That is not credible as a timing.
- The log stream was created and is empty.
- Nothing was uploaded under build/. At the time I recorded "standalone artifacts are never uploaded". **That was wrong; see Step 20 and the exercises.** The build uploaded nothing because its buildspec never ran.

## Step 14: the local runner
- usms-pack-source.sh and usms-buildspec-run.sh are verbatim and pass `bash -n`. The runner parsed with PyYAML 5.4.1.
- **Local build:** 4 phases, 7/7 smoke tests, exit 0.
- dist/build-metadata.json says "buildId": "local" and "sourceVersion": "local".
- dist/ is git-ignored by `.gitignore:37`.

## Step 15: the pipeline role and iam:PassRole
- usms-codepipeline-role: trust codepipeline.amazonaws.com, USMSCodePipelineBase v1 attached once.
- **Simulator, with iam:PassedToService:**
  - pass usms-codebuild-role to codebuild: allowed;
  - the same role to ec2: implicitDeny;
  - usms-deploy-role to codebuild: implicitDeny.

### The question: what if Resource were "*" but the condition were kept?
- **What the condition still does:** it pins the *service*, so the pipeline role could hand roles only to CodeBuild.
- **What `Resource "*"` opens:** it could hand CodeBuild *any* role. The pipeline role already has codebuild:StartBuild on usms-enrolment-build, and StartBuild takes `--service-role-override` (plus `--buildspec-override`). Anyone acting as the pipeline role could start that project as another role and run their own commands with its credentials.
- **Which role an attacker names:** the most privileged role whose trust policy lets CodeBuild assume it. PassRole decides what may be handed over; the role's trust decides whether the service can take it.
  - I checked the inventory: today only usms-codebuild-role trusts codebuild.amazonaws.com, so the escalation is latent, not live.
  - The danger is the first more powerful role that ever trusts CodeBuild: a deploy or infrastructure build role in a later lab, or someone "fixing" a role by adding CodeBuild to its trust. From that day the pipeline role could borrow it.
- usms-breakglass-role and usms-deploy-role trust only usms-admin-01, so CodeBuild could not assume them even if they were passed.
- Naming the one ARN closes this permanently, whatever trust policies change later.

## Steps 16 and 17: the pipeline
- templates/lab-11-pipeline.json has 0 `$`. usms-enrolment-pipeline was created with 2 stages (Source/S3, Build/CodeBuild).
- **Floci:** create-pipeline starts no execution. list-pipeline-executions stayed empty for 2 minutes, and get-pipeline-state reports stage and action status None for the whole lab, even after executions report Succeeded.

## Step 18: the CODEPIPELINE hand-off
- The project was converted to source and artifacts CODEPIPELINE; the image and both env vars were kept.
- **What real AWS does:** start-build on such a project raises InvalidInputException.
- **What Floci did:**
  - Build 4 was accepted and SUCCEEDED with no source.
  - `--source-type-override S3 --source-location-override ...` was ignored: build 5 still recorded CODEPIPELINE, with location None.

## Step 19: the release proof
- **r4:**
  - Uploaded as bebadecc-9c3e-4719-86f6-187a5ddd8afb.
  - Execution c8eebd61 Succeeded. Its artifactRevisions holds exactly that versionId, with revisionChangeIdentifier (the ETag) 5fc2ecef8b5c673da3cace99b1239e53.
  - No SourceOutput/ or BuildOutput/ object was ever written, and list-action-executions has no artifact keys.
  - So the "read back build-metadata.json from the artifact" half of the proof is not available on this build. The execution-to-source-version link is.
- **Your turn, r5:**
  - Uploaded as 2c559647-dea7-4f90-9adb-97c6df208581. Execution bc3851d7 Succeeded and recorded it.
  - **The counts:** 3 versions of source/usms-enrolment-src.zip (r3, r4, r5), 0 objects under usms-enrolment-pipeline/BuildOutput/, 2 executions.
- **Why the two numbers differ:**
  - A version is created by every upload. A BuildOutput object is created once per Build action that runs, under a random name.
  - So they diverge whenever an upload is not followed by an execution: r3 predates the pipeline, and with PollForSourceChanges false nothing starts on upload.
  - They also diverge when one version is built twice (a retry or a manual re-run gives two outputs for one version), and when a build fails (no output).
  - On Floci the second number is always 0: no BuildOutput is written. The pipeline's build also never runs its buildspec (Step 20's root cause).

## Step 20: the deliberate failure, and what it found
- **The deliberate break:** container `enrolment-api-v2`, uploaded as 09ee9605-18eb-4fc0-a1f7-6a2b790f037c.
  - Execution bedcb3df **Succeeded** (build 8 SUCCEEDED). On real AWS it fails at Build / PRE_BUILD.
- **Controls:**
  - The local runner on the same tree stopped in pre_build: "config/service.json names the wrong container", exit 1.
  - A standalone S3-source build (9) of the same zip also SUCCEEDED.
- **Narrowing it down:**
  - Build 10 (inline buildspec that lists the working directory, then fails) showed the container *does* receive the source: /codebuild/output/src/src holds VERSION, buildspec.yml, config, src and tests.
  - A phase matrix (builds 11-15, inline buildspecs) failed in exactly the phase that held the `exit 1`, including a `- |` block.
- **Root cause:** Floci reads the project's `buildspec` field as inline YAML, never as a path inside the source.
  - `--buildspec-override buildspec.yml` (build 16) SUCCEEDED: the string parses as a scalar with no phases, so nothing runs.
  - `--buildspec-override "$(cat buildspec.yml)"` on the same broken zip (build 17) FAILED in PRE_BUILD with the container message.
  - Every pipeline-run build in this lab therefore ran no commands at all.
- **The diagnostic chain** (stage, build, phase, command) works on build 17. It lists three FAILED rows: PRE_BUILD, POST_BUILD (Floci still ran post_build, and the smoke tests failed on the missing dist/) and COMPLETED. The lab expects one row, PRE_BUILD.
- **The fix:** container restored with the lab's json.dump. The local build passes again. Uploaded fdd913ad-7509-40ae-aa64-5ae56a177aef; execution f6980931 Succeeded.
- I left the project's buildspec field as the lab defines it, so the work matches real AWS. The gate is demonstrated with the local runner and build 17.

## Step 21: configs/lab-11.env
- 26 exports, all populated. versioning=Enabled, stages=2, release=r5, path=A.
- **As Known Issues says, it still records** USMS_BUILD_IMAGE=aws/codebuild/standard:7.0 and a BuildOutput prefix that Floci never writes. The live project runs python:3.12-slim.
- Regenerated with the same heredoc after the exercises. Only USMS_SOURCE_VERSION_ID changed, to the newest version at the key.

## Section 8
- **verify-lab-11.sh as given:** PASS=44 FAIL=2.
  - "no secret is tracked" is the outputs/.gitkeep false positive, the same as Labs 2-10. Fixed with the same one-line change, after testing it against a tracked .gitkeep, a tracked real output, and nothing tracked.
  - "project image is standard:7.0" is the stale check Known Issues names. Left as it is.
- **After the fix:** PASS=45 FAIL=1. The live readback shows python:3.12-slim. The run after the exercises gives the same 45/1.
- **lab-11-cleanup.sh:** verbatim, `bash -n` clean, **not run**.
  - It does not know about the exercise resources: usms-results-build, the EventBridge rule and target, usms-events-pipeline-role with USMSEventsStartPipeline, and the bucket's EventBridge setting.
  - Its `delete-role` for usms-codebuild-role still works; that role has one policy.

## Exercise notes
- **Exercise 1:**
  - **One sentence:** USMSCodeBuildBase already permits the results build. Its S3 statement covers the whole artifact bucket, and the template (changed only in name, source, artifact name, description and USMS_SERVICE) keeps logsConfig on /aws/codebuild/usms-enrolment-build, a group the log statement names. Give the project a log group of its own and the simulator says implicitDeny.
  - I did not add a policy version for that, because Lab 12 Step 12 creates v2 from a fixed document and its verify checks for v2.
- **Exercise 2:** `finally` is ignored by both the lab's runner (it reads only `commands`) and Floci. Probe A, a finally that exits 3, SUCCEEDED; probe B shows no finally output. The claim therefore rests on a local emulation plus the documented guarantee.
- **Exercise 3: what aws:SourceArn closes that aws:SourceAccount alone does not.**
  - **What SourceAccount does:** it means CodeBuild only uses the role on behalf of a resource in account 000000000000, which stops another account's project from borrowing it (the cross-account confused deputy).
  - **What it leaves open:** *any* CodeBuild project in our own account can still run as usms-codebuild-role. That might be a sandbox project created by a developer, or a project building an untrusted branch, given the role through a PassRole grant that is too broad (see Step 15).
  - **Why that matters:** the role can write anywhere in usms-pipeline-artifacts, including source/usms-enrolment-src.zip. Such a project could replace the source the pipeline builds next.
  - **What SourceArn adds:** CodeBuild assumes the role only for the two named projects, so a PassRole mistake alone is no longer enough. PassRole controls who may hand the role over; SourceArn controls on whose behalf the service may use it.
  - Both projects are listed because Exercise 1 reuses the role. Naming only enrolment would silently lock the results build out on real AWS.
  - **What it does not close:** deleting a project and recreating it under the same name, since the ARN is the same.
- **Exercise 4:** the S3 → EventBridge hop works on Floci and the rule matches one key. The EventBridge → CodePipeline hop is "unsupported target ARN type".
- **Exercise 5:**
  - VERSION stays r5, because Lab 12 Step 8 sets r6 itself and uses r6/r7 as image tags.
  - The exercise's upload is therefore a second, different zip labelled r5, told apart only by its versionId (33511987-9639-4bc6-a519-3b3797248fc8). That is review question 7's weakest link in practice.

## Review questions (Section 14)

**1. Source and Build succeed, and the application is unchanged.**
- **Explanation 1, `artifacts.base-directory`:** if it is missing or wrong, the artifact still uploads. Its root holds the source tree with the build output one level down, under dist/. The deploy reads files at the artifact root, finds the unbuilt sources or no imagedefinitions.json, and redeploys what was already there.
- **Explanation 2, the source zip's layout:** if the zip was made from the parent directory, the new files sit under app/. A stale buildspec.yml and src/ left at the root from an earlier layout get built instead. Everything succeeds, on old files.
- **Telling them apart:**
  - `unzip -l` on the build artifact: entries starting with dist/ mean base-directory.
  - `unzip -l` on the downloaded source version: entries under app/ mean layout. That is Step 11's "entries under app/ must be 0".
- **A third cause, seen on Floci in Step 20:** a buildspec that never ran at all. Only build output that names its release, such as build-metadata.json, catches that.

**2. Why the S3 source bucket must be versioned.**
- **An execution records its input:** each one must record exactly which bytes it took as input, and keep using those bytes for its whole life. The Build stage runs minutes after Source, and a failed stage can be retried hours later.
- **Without versioning there is no stable name:** a key names whatever was written last, so the only identifier is "the latest object", which changes under the execution.
- **The versionId is that stable name:** it is what artifactRevisions stores. Here c8eebd61 recorded bebadecc… and bc3851d7 recorded 2c559647…, which is why the executions in screenshot 3 can each be tied to their own upload, even after newer uploads.
- Rolling back is a consequence. The reason is that an execution's input must be a fixed fact, not a pointer.

**3. iam:PassRole, for someone who thinks it is redundant.**
- **The objection is reasonable:** the two permissions are usually granted together.
- **The two permissions answer different questions:** "may you create projects?" is about an action. "Which identities may you lend to CodeBuild?" is about authority you don't hold yourself.
- **The project then acts with that identity:** a project runs as its role and executes whatever buildspec you give it, so choosing the role chooses the permissions your code will have.
- **Without a separate check, creating a project means becoming any role:** anyone allowed to create a project could name the most powerful role CodeBuild can assume and run their own commands with it.
- **PassRole makes delegation its own decision:** it names which roles, and with iam:PassedToService to which service. It is checked once, when the role is attached (CreateProject, UpdateProject, or StartBuild with an override), because after that the service acts on its own.

**4. One role or two.**
- **For two roles:**
  - The build role runs arbitrary code from the source zip, so whoever can change the source effectively controls it. It gets the least: its own logs, the artifact store, and an explicit Deny on student records.
  - The pipeline role orchestrates: it starts one project and passes one role.
  - Merged, code in a buildspec could start builds, pass roles and read every artifact. A source-level compromise becomes a pipeline-level compromise.
  - Each role also trusts one service with its own conditions, and CloudTrail shows which principal did what.
- **The strongest argument against, in this lab:**
  - The split protects less than it appears to. The build role can already PutObject anywhere in usms-pipeline-artifacts, including source/usms-enrolment-src.zip, so a malicious build can rewrite the source the next execution builds.
  - That is most of what the pipeline role's extra powers would add. Until the build's write access is narrowed to its own output prefix, the separation is largely ceremonial.
  - Meanwhile it costs coupling: the pipeline policy names the build role and project ARNs, so every new project (Exercise 1) needs edits in two documents.

**5. The three heredoc forms.**
- **`<< 'BUILDSPEC'` (quoted, Step 8):**
  - **What it must do:** write `$USMS_RELEASE`, `$(date ...)` and `${CODEBUILD_BUILD_ID:-local}` literally, to be expanded at build time.
  - **If it were unquoted:** my shell would expand them while writing. The release would be empty, the time frozen at the moment of writing, and the build ID "local" forever.
  - **Why no error:** the YAML stays valid and the build still succeeds; the metadata simply lies.
- **`<< META` (unquoted, inside the buildspec):**
  - **What it must do:** expand at build time.
  - **If it were quoted:** build-metadata.json would contain the literal string `$USMS_RELEASE`.
  - **Why no error:** that is still valid JSON, so the "build metadata is valid JSON" smoke test passes.
- **`<< EOF` (unquoted, Step 21):**
  - **What it must do:** run every `$(aws ...)` now and store the values.
  - **If it were quoted:** the env file would contain the command substitutions, and every later `source` would call Floci again. It would get whatever the state is *then*, or `not-created` when Floci is down, because of `|| echo`.
  - **Why no error:** the "no empty values" check passes, since `$(...)` text isn't empty.
- **Why none of the three complains:** each writes a file successfully. Bash cannot know which you meant, because "write the text" and "write the result" are both legal requests.

**6. "pre_build's validation duplicates the deploy stage's check."**
- **When the colleague is right:**
  - The deploy stage checks the same fact, before it changes anything, with a message as clear.
  - Nothing irreversible happens in between: the artifact goes nowhere else and building is cheap.
  - A duplicate check is a second place to update when the rule changes; Exercise 3's grep had already drifted from the JSON it was meant to check.
- **When they are expensively wrong:**
  - The deploy's "check" is the failure itself. Step 2 of this lab warns that a container-name mismatch "produces a deploy failure whose message does not name the container", and it arrives after an image was pushed, a task definition registered and the service updated.
  - Or failing late is not clean: tasks fail health checks until the circuit breaker rolls back, and the service is degraded for minutes.
  - Or the artifact has other consumers, such as another environment or a manual promotion, that never run the deploy stage's check.
- **The rule:** fail at the cheapest point that can know, with a message that names the fix.
- **Step 20 shows the opposite:** with no gate actually running, a broken source went all the way to "Succeeded".

**7. Proving r4 was built from the repository as it stood on a given date.**
- **The chain, using only what this lab created:**
  1. The git commit containing labs/lab-11-cicd/app with VERSION r4.
  2. The zip that usms-pack-source.sh made from that tree.
  3. S3 version bebadecc-9c3e-4719-86f6-187a5ddd8afb of source/usms-enrolment-src.zip, with its LastModified (2026-11-09T04:17:27Z) and ETag (5fc2ecef8b5c673da3cace99b1239e53).
  4. Pipeline execution c8eebd61, whose artifactRevisions records that versionId and ETag.
  5. The build that execution ran, and the artifact's build-metadata.json naming release, buildId and sourceVersion.
- **The weakest link is the first hop, repository to zip:**
  - The zip is packed from my working tree, not from a commit. Uncommitted edits go in, and nothing records a commit hash in the zip or in the metadata.
  - "r4" is a label typed into VERSION. In Exercise 5 I uploaded a second, different zip still labelled r5, and only its versionId tells them apart.
- **Floci weakens the far end too:** sourceVersion is "local" and no BuildOutput exists. But the repository-to-zip gap would exist on real AWS as well.
- **The fix:** write `git rev-parse HEAD` into the zip and into build-metadata.json, and refuse to pack a dirty tree.
