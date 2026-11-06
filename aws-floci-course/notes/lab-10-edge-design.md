# Transcript delivery: edge design (Lab 10 Exercise 4)

For: the USMS registrar and whoever implements this after Lab 10.

The requirements, restated:
- Transcripts are never served without a valid session token, and the check costs no origin request.
- A corrected transcript stops being served within five minutes of the correction, but unchanged transcripts are not re-fetched every five minutes.
- The Dean's office gets a count of refused transcript requests, by faculty.
- The service survives one edge location being unable to reach the origin.

## 1. Where each piece of logic runs

| Logic | Where | Why |
|---|---|---|
| Lowercase the URI | **CloudFront Function**, viewer-request | Pure string work on every request. CloudFront Functions run sub-millisecond, cost a fraction of Lambda@Edge, and need no network: exactly this job. |
| Check the session token, and that the token's student matches the transcript in the path | **CloudFront Function** at viewer-request, if the token is an HMAC-signed (HS256) JWT; otherwise **Lambda@Edge** at viewer-request | It must run before the cache on every request, or a cached transcript would be served without a check. A CloudFront Function is enough if `cloudfront-js-2.0`'s `crypto` module covers the token's algorithm, with the key in a CloudFront KeyValueStore. **I'd verify that first:** I'm sure of HMAC support, not of RSA signature verification. If the token is RS256, or validation needs a revocation lookup, it has to be Lambda@Edge. |
| The alternative to both: let CloudFront check access itself | **CloudFront signed cookies** (trusted key groups) | The portal sets a signed cookie at login, and CloudFront refuses any request without a valid one. No function runs at all. This is the option I'd evaluate first. The trade-off: it proves "logged in", not "this student", so per-student authorisation still needs a function. |
| Security headers | **Lambda@Edge, origin-response** (as built in this lab), or a CloudFront **response headers policy** | A response headers policy does it with no code and no invocation charge. I'd move to it; the Lab 10 function exists to teach the trigger point. |
| Invalidate a corrected transcript | **Regional Lambda**, triggered by S3 `ObjectCreated` on an existing key | Nobody is waiting for it, it calls the CloudFront API, and it belongs next to the data. It's an extension of `usms-transcript-notifier`. |
| The refusal report by faculty | **Regional**: a scheduled query over CloudFront logs | It isn't on the request path at all (section 4). |

## 2. The cache key

**In the key:** the normalised URI only (`/transcripts/<year>/<student>.json`). Each transcript is then one cache entry, shared by every viewer allowed to see it.

**Deliberately left out:**
- **The session token or cookie.** Every login would create its own copy of every transcript, and the cache would never hit.
- **The `x-usms-student` header.** The Lab 10 configuration forwards it. That multiplies copies and buys nothing, because the authorisation check runs at viewer-request *before* the cache on every request, so a shared cache entry is safe.
- **Query strings and the `Accept-Language` header.**

The URI-only key is safe *only* because the token check runs before the cache and compares the token's student with the student in the path. If that check moved to origin-request (after the cache), a URI-only key would serve one student's cached transcript to another. That's the most important sentence in this design.

## 3. Five-minute corrections without re-fetching every five minutes

Two defensible answers:

**(a) A long edge TTL, plus invalidation on correction (my choice).**
- Set `Cache-Control: max-age=300, s-maxage=86400`: browsers recheck after 5 minutes, and the edge keeps the object for a day.
- When a corrected transcript is uploaded over an existing key, the regional function calls `CreateInvalidation` for that one path. Invalidation takes effect across edge locations in well under five minutes, and the first 1,000 invalidation paths each month are free (CloudFront pricing page).
- Unchanged transcripts are fetched from the origin about once a day per edge location.
- The browser half matters: `max-age=300` means a browser that already holds the old copy uses it for at most five more minutes.

**(b) A short TTL, with conditional revalidation.**
- Set `s-maxage=300`. When the edge copy expires, CloudFront revalidates with `If-None-Match` (the ETag), and S3 answers `304 Not Modified` with no body when the transcript hasn't changed.
- That's an origin request every five minutes per edge location, but not a re-fetch of the content. It reads the requirement as "don't pay to transfer unchanged transcripts".

(a) meets the requirement literally. (b) is simpler and has no invalidation code to fail. I'd choose (a), with (b)'s ETag behaviour as the fallback if an invalidation call fails.

## 4. Where the refusal report comes from

Lambda@Edge logs land in **the region nearest each viewer**, under `/aws/lambda/us-east-1.<function>`, so counting refusals from function logs means querying every region. Instead:
- **CloudFront standard logs** (or real-time logs to Kinesis) go to **one** S3 bucket.
- A refusal generated at viewer-request appears there with status 403 and an edge result type showing that a function generated the response. I'd verify the exact `x-edge-result-type` value for CloudFront Functions versus Lambda@Edge before writing the query.
- A scheduled regional job (Athena over the log bucket) counts 403s per day and maps each to a faculty from the student-number prefix in the URI, then writes the report.
- This also needs no work at the edge, which keeps the viewer-request function fast.

## 5. Surviving an edge location that can't reach the origin

- An **origin group**: primary origin `usms-student-data` in us-east-1, failover origin a cross-region replica of the bucket. CloudFront retries the secondary on 5xx or a connection failure.
- **`stale-if-error`** in the transcript `Cache-Control`: an edge location that can't reach either origin serves its stale copy rather than an error. **To verify:** that CloudFront honours `stale-if-error` for this distribution's cache policy.
- The authorisation check needs no origin and no network (a CloudFront Function, or a signed cookie), so refusals keep working during an origin outage too.

## 6. The requirement an edge function is the wrong tool for

**The Dean's refusal report.** It aggregates across every edge location and every day. Building it inside the request path would add latency to every transcript request and scatter state across regions. It belongs in a regional job over centralised logs (section 4). The invalidation on correction (section 3) is the second example: it reacts to a write, and no viewer is waiting.

## 7. What I'd measure first, and what would change my mind

**First, the transcript cache hit ratio and the origin request rate**, from CloudFront's statistics, over a results week.
- If most transcripts are requested only once or twice (one student, one download), the edge cache barely helps, a long s-maxage buys nothing, and design 3(b) becomes the simpler right answer.
- If a small set of transcripts is requested many times (a department downloading a cohort), 3(a) pays for itself.

**Second, the share of 403s at viewer-request.** A high rate from a few IPs means abuse, and that calls for AWS WAF rate-based rules in front of CloudFront rather than more function logic.
