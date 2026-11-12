// Online exam platform - browser client (no framework, no build step).
// Talks to Cognito for sign-in, to the API for everything else, and straight to S3
// for uploads (with a presigned POST the API signs).
"use strict";

const CFG = window.EXAM_CONFIG || {};
const params = new URLSearchParams(location.search);
// ?autosave=5 shortens the 30-second autosave for a demo recording.
const AUTOSAVE_SECONDS = Number(params.get("autosave")) || CFG.autosaveSeconds || 30;
const $ = (id) => document.getElementById(id);

const state = { token: null, user: null, attempt: null, seq: 0, dirty: false, timers: [], retryMs: 2000 };

// ------------------------------------------------------------------ activity log

function log(text, ok = true) {
  const li = document.createElement("li");
  li.className = ok ? "ok" : "bad";
  li.textContent = `${new Date().toLocaleTimeString()}  ${text}`;
  $("log").prepend(li);
}
$("clear-log").onclick = () => { $("log").innerHTML = ""; };

// ------------------------------------------------------------------ sign-in (Cognito)

async function signIn(email, password) {
  const t0 = performance.now();
  const res = await fetch(CFG.cognitoEndpoint + "/", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth",
    },
    body: JSON.stringify({ AuthFlow: "USER_PASSWORD_AUTH", ClientId: CFG.clientId,
                           AuthParameters: { USERNAME: email, PASSWORD: password } }),
  });
  const body = await res.json().catch(() => ({}));
  log(`Cognito InitiateAuth -> ${res.status} (${Math.round(performance.now() - t0)} ms)`, res.ok);
  if (!res.ok || !body.AuthenticationResult) throw new Error(body.message || "Sign-in failed");
  return body.AuthenticationResult.IdToken;
}

function claims(token) {
  const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(atob(part + "=".repeat((4 - part.length % 4) % 4)));
}

$("login-form").onsubmit = async (e) => {
  e.preventDefault();
  $("login-error").textContent = "";
  try {
    const token = await signIn($("login-email").value.trim(), $("login-password").value);
    sessionStorage.setItem("idToken", token);
    start(token);
  } catch (err) {
    $("login-error").textContent = err.message;
  }
};

function signOut() {
  sessionStorage.removeItem("idToken");
  state.timers.forEach(clearInterval);
  location.reload();
}

// ------------------------------------------------------------------ API

async function api(method, path, body) {
  const t0 = performance.now();
  const res = await fetch(`${CFG.apiBase}/api${path}`, {
    method,
    headers: { "Content-Type": "application/json", Authorization: state.token },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  log(`${method} /api${path} -> ${res.status} (${Math.round(performance.now() - t0)} ms)`, res.ok);
  if (res.status === 401) { signOut(); }
  if (!res.ok) throw Object.assign(new Error(data.error || data.message || `HTTP ${res.status}`), { status: res.status });
  return data;
}

// ------------------------------------------------------------------ layout

const TABS = {
  students: [["exams", "My exams"], ["upload", "Upload assignment"]],
  tutors: [["submissions", "Submissions"], ["create", "Create exam"], ["results", "Release results"]],
};

function showTab(name) {
  document.querySelectorAll("[id^=tab-]").forEach((s) => { s.hidden = s.id !== `tab-${name}`; });
  document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("active", b.dataset.tab === name));
  ({ exams: loadExams, submissions: loadSubmissions, results: loadRelease })[name]?.();
}

function start(token) {
  state.token = token;
  const c = claims(token);
  let groups = c["cognito:groups"] || [];
  if (typeof groups === "string") groups = groups.replace(/[\[\]]/g, "").split(/[ ,]+/).filter(Boolean);
  if (groups.includes("admins")) groups = ["students", "tutors", "admins"];
  state.user = { email: c.email || c["cognito:username"], groups };
  $("who").innerHTML = "";
  $("who").append(`${state.user.email} · ${groups.filter((g) => g !== "admins").join(", ") || "no role"}`);
  const out = document.createElement("button"); out.textContent = "Sign out"; out.onclick = signOut;
  $("who").append(out);
  $("view-login").hidden = true;
  $("view-app").hidden = false;
  const tabs = groups.flatMap((g) => TABS[g] || []);
  $("tabs").innerHTML = "";
  for (const [key, label] of tabs) {
    const b = document.createElement("button");
    b.textContent = label; b.dataset.tab = key; b.onclick = () => showTab(key);
    $("tabs").append(b);
  }
  if (tabs.length) showTab(tabs[0][0]);
}

// ------------------------------------------------------------------ walkthrough 1: exams and autosave

async function loadExams() {
  const { exams } = await api("GET", "/exams");
  $("exam-rows").innerHTML = "";
  for (const ex of exams) {
    const tr = document.createElement("tr");
    const status = ex.attempt ? ex.attempt.status.replace("_", " ") : "not started";
    tr.innerHTML = `<td>${ex.title}</td><td>${ex.duration_min} min</td><td>${status}</td><td></td>`;
    const b = document.createElement("button");
    b.textContent = !ex.attempt ? "Start" : ex.attempt.status === "in_progress" ? "Resume" : "View result";
    b.onclick = () => (ex.attempt && ex.attempt.status !== "in_progress") ? showResult(ex.attempt.id) : openExam(ex.id);
    tr.lastChild.append(b);
    $("exam-rows").append(tr);
  }
}

function localKey() { return `answers:${state.attempt.id}`; }

async function openExam(examId) {
  const data = await api("POST", `/exams/${examId}/attempts`);
  state.attempt = { ...data.attempt, examTitle: data.exam.title };
  // Server time is the clock; the browser only counts down from the offset.
  state.attempt.offsetMs = new Date(data.attempt.serverTime) - Date.now();
  const local = JSON.parse(localStorage.getItem(localKey()) || "null");
  const answers = { ...data.savedAnswers, ...(local ? local.answers : {}) };
  state.seq = local ? local.seq : 0;
  renderQuestions(data.questions, answers);
  $("attempt-title").textContent = data.exam.title;
  $("attempt-result").textContent = "";
  document.querySelectorAll("[id^=tab-]").forEach((s) => { s.hidden = s.id !== "tab-attempt"; });
  state.timers.forEach(clearInterval);
  state.timers = [setInterval(tick, 1000), setInterval(autosave, AUTOSAVE_SECONDS * 1000)];
  setSave("ok", `Autosave every ${AUTOSAVE_SECONDS} s`);
  if (local && local.dirty) { state.dirty = true; autosave(); } // finish a save that never reached the server
  tick();
}

function renderQuestions(questions, answers) {
  const f = $("questions"); f.innerHTML = "";
  for (const q of questions) {
    const box = document.createElement("div"); box.className = "q";
    box.innerHTML = `<p>${q.position}. ${q.prompt} <span class="muted">(${q.marks} mark${q.marks > 1 ? "s" : ""})</span></p>`;
    if (q.kind === "mcq") {
      for (const opt of q.options) {
        const l = document.createElement("label");
        const r = Object.assign(document.createElement("input"), { type: "radio", name: q.id, value: opt, checked: answers[q.id] === opt });
        r.onchange = markDirty; l.append(r, opt); box.append(l);
      }
    } else {
      const t = Object.assign(document.createElement("textarea"), { name: q.id, value: answers[q.id] || "" });
      t.oninput = markDirty; box.append(t);
    }
    f.append(box);
  }
}

function collectAnswers() {
  const out = {};
  for (const el of $("questions").elements) {
    if (el.type === "radio") { if (el.checked) out[el.name] = el.value; else if (!(el.name in out)) out[el.name] = null; }
    else if (el.name) out[el.name] = el.value;
  }
  return out;
}

function markDirty() {
  state.dirty = true;
  // Keep a local copy at once: even if the network or the database is briefly
  // unavailable, nothing typed is lost; the next autosave sends it.
  localStorage.setItem(localKey(), JSON.stringify({ answers: collectAnswers(), seq: state.seq, dirty: true }));
  setSave("saving", "Unsaved changes (kept on this device)");
}

function setSave(kind, text) { $("save-dot").className = `dot ${kind}`; $("save-status").textContent = text; }

async function autosave(force = false) {
  if (!state.attempt || (!state.dirty && !force)) return;
  const seq = ++state.seq;
  const answers = collectAnswers();
  setSave("saving", "Saving...");
  try {
    const r = await api("PUT", `/attempts/${state.attempt.id}/answers`, { answers, seq });
    state.dirty = false; state.retryMs = 2000;
    localStorage.setItem(localKey(), JSON.stringify({ answers, seq, dirty: false }));
    setSave("ok", `Saved at ${new Date(r.savedAt).toLocaleTimeString()} (save #${seq})`);
  } catch (err) {
    if (err.status === 409) { setSave("bad", err.message); return stopExam(); }
    // Network error or 5xx (e.g. during a database failover): keep the local copy, retry with backoff.
    setSave("bad", `Save failed (${err.message}); retrying in ${state.retryMs / 1000} s`);
    setTimeout(() => autosave(true), state.retryMs);
    state.retryMs = Math.min(state.retryMs * 2, 30000);
  }
}
$("save-now").onclick = () => autosave(true);

function tick() {
  if (!state.attempt) return;
  const left = Math.max(0, Math.round((new Date(state.attempt.deadline) - (Date.now() + state.attempt.offsetMs)) / 1000));
  $("timer").textContent = `${String(Math.floor(left / 60)).padStart(2, "0")}:${String(left % 60).padStart(2, "0")}`;
  $("timer").classList.toggle("low", left < 120);
  if (left === 0) submitAttempt();
}

function stopExam() { state.timers.forEach(clearInterval); state.timers = []; }

async function submitAttempt() {
  if (!state.attempt) return;
  stopExam();
  await autosave(true);
  const r = await api("POST", `/attempts/${state.attempt.id}/submit`);
  localStorage.removeItem(localKey());
  $("attempt-result").textContent = `Submitted. Marking is ${r.marking}; your score appears here once your tutor releases results.`;
  $("submit-attempt").disabled = true;
}
$("submit-attempt").onclick = () => { if (confirmSubmit()) submitAttempt(); };
function confirmSubmit() { return window.EXAM_CONFIG.environment === "floci" || window.confirm("Submit your exam now?"); }

async function showResult(attemptId) {
  const r = await api("GET", `/attempts/${attemptId}`);
  document.querySelectorAll("[id^=tab-]").forEach((s) => { s.hidden = s.id !== "tab-attempt"; });
  $("attempt-title").textContent = r.examId; $("questions").innerHTML = ""; $("timer").textContent = "--:--";
  $("submit-attempt").disabled = true; $("save-now").disabled = true;
  setSave(r.status === "marked" ? "ok" : "saving", `Status: ${r.status}`);
  $("attempt-result").textContent = r.mcqScore === undefined
    ? "Results have not been released yet."
    : `Multiple-choice score: ${r.mcqScore} / ${r.maxMcqScore}` + (r.pendingShortAnswers ? ` · ${r.pendingShortAnswers} short answer(s) awaiting your tutor` : "");
}

// ------------------------------------------------------------------ walkthrough 2: upload

$("upload-go").onclick = async () => {
  const file = $("upload-file").files[0];
  const status = $("upload-status");
  if (!file) { status.textContent = "Choose a PDF or ZIP file first."; return; }
  if (file.size > (CFG.maxUploadBytes || 52428800)) { status.textContent = "That file is over 50 MB."; return; }
  const type = file.type || (file.name.endsWith(".zip") ? "application/zip" : "application/pdf");
  try {
    const r = await api("POST", "/assignments/DSO303-A2/upload-url", { filename: file.name, size: file.size, contentType: type });
    const form = new FormData();
    for (const [k, v] of Object.entries(r.upload.fields)) form.append(k, v);
    form.append("file", file); // must be last
    $("upload-progress").hidden = false;
    const t0 = performance.now();
    const code = await new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open("POST", r.upload.url);
      xhr.upload.onprogress = (e) => { if (e.lengthComputable) $("upload-progress").value = (100 * e.loaded) / e.total; };
      xhr.onload = () => resolve(xhr.status);
      xhr.onerror = () => reject(new Error("network error during upload"));
      xhr.send(form);
    });
    const mb = (file.size / 1048576).toFixed(1);
    log(`POST ${new URL(r.upload.url).pathname} (S3 presigned, ${mb} MB) -> ${code} (${Math.round(performance.now() - t0)} ms)`, code < 300);
    if (code >= 300) throw new Error(`storage rejected the upload (HTTP ${code})`);
    status.textContent = `Uploaded ${file.name} (${mb} MB). Submission ${r.submissionId} is being checked; you and your tutor will get an e-mail.`;
  } catch (err) {
    status.textContent = `Upload failed: ${err.message}`;
  }
};

// ------------------------------------------------------------------ tutor views

async function loadSubmissions() {
  const { submissions } = await api("GET", "/submissions?assignmentId=DSO303-A2");
  $("sub-rows").innerHTML = "";
  for (const s of submissions) {
    const tr = document.createElement("tr");
    const size = s.size_bytes || s.declared_bytes;
    tr.innerHTML = `<td>${s.student_email}</td><td>${s.filename}</td><td>${(size / 1048576).toFixed(1)} MB</td>
      <td class="status-${s.status}">${s.status.replace("_", " ")}</td>
      <td>${s.received_at ? new Date(s.received_at).toLocaleString() : ""}</td><td></td>`;
    if (s.status === "received") {
      const b = document.createElement("button"); b.className = "secondary"; b.textContent = "Download";
      b.onclick = async () => { const r = await api("GET", `/submissions/${s.id}/download-url`); window.open(r.url, "_blank"); };
      tr.lastChild.append(b);
    }
    $("sub-rows").append(tr);
  }
}
$("refresh-subs").onclick = loadSubmissions;

$("create-go").onclick = async () => {
  const questions = $("new-questions").value.split("\n").map((l) => l.trim()).filter(Boolean).map((line) => {
    const parts = line.split("|").map((p) => p.trim());
    if (parts.length === 1) return { kind: "short", prompt: parts[0], marks: 2 };
    const options = parts.slice(1).map((o) => o.replace(/^\*/, "").trim());
    const key = parts.slice(1).find((o) => o.startsWith("*"));
    return { kind: "mcq", prompt: parts[0], options, answerKey: key ? key.slice(1).trim() : undefined };
  });
  try {
    const r = await api("POST", "/exams", { title: $("new-title").value, durationMin: Number($("new-duration").value), questions });
    $("create-status").textContent = `Created ${r.examId} with ${r.questions} questions. Students can start it now.`;
  } catch (err) {
    $("create-status").textContent = `Not created: ${err.message}`;
  }
};

async function loadRelease() {
  const { exams } = await api("GET", "/exams");
  $("release-rows").innerHTML = "";
  for (const ex of exams) {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td>${ex.title}</td><td>${ex.released ? "yes" : "no"}</td><td></td>`;
    const b = document.createElement("button"); b.textContent = ex.released ? "Release again" : "Release results";
    b.onclick = async () => {
      const r = await api("POST", `/exams/${ex.id}/release`);
      $("release-status").textContent = `Released ${r.examId}; result e-mails are ${r.emails}.`;
      loadRelease();
    };
    tr.lastChild.append(b);
    $("release-rows").append(tr);
  }
}

// ------------------------------------------------------------------ boot

$("env").textContent = CFG.environment === "floci" ? "Floci" : "AWS";
const saved = sessionStorage.getItem("idToken");
if (saved && claims(saved).exp * 1000 > Date.now()) start(saved);
