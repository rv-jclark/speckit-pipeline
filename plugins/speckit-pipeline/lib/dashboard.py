#!/usr/bin/env python3
"""spec-dashboard's collector and server. Run through bin/spec-dashboard.

Reads every spec-run state file and every roadmap state file under the given
roots, gives each one a verdict, and serves the result to a single page on
loopback.

What "complete" means is decided here, once, and the page only draws it.
Deciding it in the browser as well would give two places with an opinion on
whether work is finished, and they would drift apart.

Nothing here writes. In particular, a `running` phase whose runner is gone is
REPORTED as crashed. It is never relabelled `interrupted` the way
state_reconcile_running does. A dashboard that rewrites the files it is
displaying would be changing the evidence while showing it to you.
"""

import json
import re
import os
import shlex
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHASES_JSON = os.path.join(ROOT, "lib", "phases.json")
PAGE = os.path.join(ROOT, "assets", "dashboard", "index.html")

# A phase in one of these states stopped without finishing, so someone has to act.
BLOCKING = {"needs_input", "failed", "interrupted", "blocked", "limited"}
# Statuses that count as a pass for the purpose of moving on. `unevaluated` is
# not a pass (the README is explicit about that), but analyze records it as its
# normal outcome, and treating it as a stop would flag every pipeline that ran
# analyze as unfinished.
PASSED = {"ok", "unevaluated", "skipped"}

# Discovery shells out to git once per candidate directory, which is the
# expensive part of a refresh. Repositories appear and disappear far less often
# than the page polls, so the list of them is cached.
DISCOVERY_TTL = 60


def phase_order():
    try:
        with open(PHASES_JSON) as f:
            spec = json.load(f)
        return [p.get("id") or p.get("name") for p in spec.get("phases", [])]
    except (OSError, ValueError):
        return ["specify", "clarify", "plan", "tasks", "analyze", "remediate",
                "converge", "implement", "review"]


ORDER = phase_order()


def _gitdir_of(path):
    """The resolved git directory of a checkout, read from disk.

    No `git` subprocess: discovery touches over a hundred checkouts on a
    working laptop, and a `git rev-parse` each was measured at 13 seconds of
    the 21 a refresh took. `.git` is a directory in a main checkout and a
    one-line `gitdir: <path>` file in a linked worktree, and those are the
    only two shapes this needs to tell apart.
    """
    dotgit = os.path.join(path, ".git")
    if os.path.isdir(dotgit):
        return dotgit
    try:
        with open(dotgit) as f:
            line = f.readline().strip()
    except OSError:
        return None
    if not line.startswith("gitdir:"):
        return None
    gd = line[len("gitdir:"):].strip()
    return os.path.normpath(os.path.join(path, gd))


def _is_checkout(path):
    return os.path.exists(os.path.join(path, ".git"))


def _project_of(path):
    """(project name, project path), using the MAIN checkout's for a worktree too.

    A pipeline run in ~/code/agents-wt/foo belongs to `agents`. Grouping by
    directory name would put it under `foo`, and one project's work would be
    split across as many groups as it has worktrees.
    """
    gd = _gitdir_of(path)
    marker = os.sep + ".git" + os.sep + "worktrees" + os.sep
    if gd and marker in gd:
        main = gd.split(marker, 1)[0]
        return os.path.basename(main), main
    return os.path.basename(path.rstrip(os.sep)), path


def _worktrees_of(path):
    """Linked worktrees of a main checkout, from .git/worktrees/*/gitdir."""
    base = os.path.join(path, ".git", "worktrees")
    try:
        names = os.listdir(base)
    except OSError:
        return []
    out = []
    for n in names:
        try:
            with open(os.path.join(base, n, "gitdir")) as f:
                out.append(os.path.dirname(f.readline().strip()))
        except OSError:
            pass
    return out


def discover(roots):
    """Every checkout under the roots, plus every worktree those checkouts know about.

    Two levels down is enough for ~/code/<repo> and ~/code/<group>/<repo>.
    Worktrees can be anywhere on disk, so they come from the main checkout's
    own record of them rather than from walking the filesystem.
    """
    seen, out = set(), []

    def add(path):
        real = os.path.realpath(path)
        if real in seen or not os.path.isdir(real):
            return
        seen.add(real)
        out.append(real)

    candidates = []
    for root in roots:
        root = os.path.expanduser(root)
        if _is_checkout(root):
            candidates.append(root)
        try:
            level1 = sorted(os.scandir(root), key=lambda e: e.name)
        except OSError:
            continue
        for e in level1:
            if not e.is_dir() or e.name.startswith("."):
                continue
            if _is_checkout(e.path):
                candidates.append(e.path)
                continue
            try:
                for e2 in sorted(os.scandir(e.path), key=lambda e: e.name):
                    if e2.is_dir() and not e2.name.startswith(".") and _is_checkout(e2.path):
                        candidates.append(e2.path)
            except OSError:
                pass

    for c in candidates:
        add(c)
        for w in _worktrees_of(c):
            add(w)
    return out


def runner_table(pids=()):
    """{pid: command} for the given pids, or None when the table cannot be read.

    Only the pids recorded as running are asked about. Listing every process on
    the machine took most of a second, and longer under load, on every refresh.

    None means CANNOT TELL. It does not mean "no runners". Inside Claude Code's
    Bash sandbox `ps` on a foreign pid is refused, so an empty table there would
    mark every live run as crashed. common.sh's _runner_alive works the same
    way, for the same reason.
    """
    want = ",".join(str(p) for p in sorted({os.getpid(), *pids}))
    try:
        # Exits 1 when some of the pids are gone, which is the normal case
        # here, so the exit status is ignored and the rows are what count.
        out = subprocess.run(["ps", "-o", "pid=,command=", "-p", want], capture_output=True,
                             text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    table = {}
    for line in out.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            table[int(parts[0])] = parts[1]
    # The same self-probe as common.sh: if our own pid is missing, the table is
    # not trustworthy, however many rows it returned.
    return table if os.getpid() in table else None


def runner_state(pid, table):
    if table is None:
        return "unknown"
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return "gone"
    # Matching the command line as well as the pid: a bare pid check is fooled
    # by pid reuse, and after a reboot every recorded pid is a stranger's.
    return "alive" if "spec-run" in table.get(pid, "") else "gone"


# Parsed results keyed by path, and reused while the file's mtime and size are
# unchanged. A refresh used to re-read every state file, roadmap file and
# tasks.md. That was 614 JSON parses, and 258 of them were copies of 24
# roadmaps, committed into every worktree. Almost none change between refreshes.
# The results are shared, so callers must not mutate them.
_FILE_CACHE = {}


def _cached(path, parse):
    try:
        st = os.stat(path)
    except OSError:
        _FILE_CACHE.pop(path, None)
        return parse(None)
    sig = (st.st_mtime_ns, st.st_size)
    hit = _FILE_CACHE.get(path)
    if hit and hit[0] == sig:
        return hit[1]
    val = parse(path)
    _FILE_CACHE[path] = (sig, val)
    return val


def _parse_json(path):
    if path is None:
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _read_json(path):
    return _cached(path, _parse_json)


# The same three patterns as spec-run's tasks_unchecked and _tasks_blocked, and
# verify.sh's _task_counts. If those change, these must change with them.
_UNCHECKED = re.compile(r"^[ \t]*-[ \t]*\[[ \t]\]")
_ANY_BOX = re.compile(r"^[ \t]*[-*][ \t]+\[[ \txX]\]")
_BLOCKED = re.compile(r"^[ \t]*-[ \t]*\[[ \t]\][ \t]*(T[0-9]+[ \t]+)?(\[[A-Z0-9]+\][ \t]*)*🛑[ \t]*BLOCKED")


def task_counts(feature_dir):
    """{total, done, open, blocked} from tasks.md. `open` excludes 🛑 BLOCKED tasks."""
    return _cached(os.path.join(feature_dir, "tasks.md"), _parse_tasks)


_TID = re.compile(r"T[0-9]+")
_CHECKED = re.compile(r"^[ \t]*[-*][ \t]+\[[xX]\]")


def _parse_tasks(path):
    total = unchecked = blocked = 0
    try:
        if path is None:
            raise OSError
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        lines = []
    done = {m.group(0) for l in lines if _CHECKED.match(l) for m in [_TID.search(l)] if m}
    for line in lines:
        if _ANY_BOX.match(line):
            total += 1
        if _UNCHECKED.match(line):
            unchecked += 1
            if _BLOCKED.match(line):
                # Same staleness rule as verify.sh's _tasks_blocked (#17): a
                # marker whose reason names only tasks now ticked is open work.
                own = _TID.search(line)
                named = [t for t in _TID.findall(line.split("BLOCKED", 1)[1])
                         if not own or t != own.group(0)]
                if named and all(t in done for t in named):
                    continue
                blocked += 1
    return {"total": total, "done": total - unchecked, "open": unchecked - blocked,
            "blocked": blocked}


def _q(s):
    return shlex.quote(s)


def _ts(*vals):
    vals = [v for v in vals if v]
    return max(vals) if vals else None


def pipeline_record(state_path, checkout, project, table):
    st = _read_json(state_path)
    if not isinstance(st, dict):
        return None
    feature_dir = os.path.dirname(os.path.dirname(state_path))
    feature = os.path.basename(feature_dir)
    rel = os.path.relpath(feature_dir, checkout)

    phases = []
    for name, p in (st.get("phases") or {}).items():
        if not isinstance(p, dict):
            continue
        rs = runner_state(p.get("runner_pid"), table) if p.get("status") == "running" else None
        phases.append({
            "name": name,
            "status": p.get("status") or "",
            "model": p.get("model") or "",
            "cost": p.get("cost_usd") or 0,
            "note": p.get("note") or "",
            "session_id": p.get("session_id") or "",
            "started_at": p.get("started_at"),
            "finished_at": p.get("finished_at"),
            "runner": rs,
        })
    idx = {n: i for i, n in enumerate(ORDER)}
    phases.sort(key=lambda p: idx.get(p["name"], len(ORDER)))

    # The verdict comes from the phase that ran LAST, not the first one that
    # failed. Real state files have `specify=failed plan=ok tasks=ok
    # implement=ok`, which means a failure that was later worked past, and
    # converge runs after implement even though phases.json lists it first. So
    # the order in the file says nothing about what happened when. started_at
    # does.
    running = [p for p in phases if p["status"] == "running"]
    latest = max(phases, key=lambda p: (p["started_at"] or "", idx.get(p["name"], -1)),
                 default=None)
    by_name = {p["name"]: p for p in phases}
    impl = by_name.get("implement", {}).get("status")
    review = by_name.get("review", {}).get("status")

    tasks = task_counts(feature_dir)
    # Is the work actually done? implement records `ok` per PASS. A chunked
    # implement says "pass done — 1 of 75 task(s) left for the next pass" and
    # is still `ok`, so the status alone would call that finished. The open
    # task count is the only authority, the same as spec-run's tasks_open.
    finished = (impl in PASSED and tasks["open"] == 0
                and review not in BLOCKING and review != "running")

    at, note, sid = None, "", ""
    if running:
        p = running[0]
        at, sid = p["name"], p["session_id"]
        verdict = {"alive": "running", "gone": "crashed"}.get(p["runner"], "unknown")
        if verdict == "crashed":
            note = "marked running, but its runner process is gone"
        elif verdict == "unknown":
            note = "the process table cannot be read here, so liveness is unknown"
    elif latest is None:
        verdict = "paused"
        note = "no phase has run"
    elif finished:
        verdict, at = "complete", latest["name"]
        # A pre-implement phase re-run AFTER the work landed, and failed. Seen
        # for real: `specify=failed` dated two days after `implement=ok`. The
        # feature is done, so calling it failed would bury it among the
        # genuinely stuck ones. Saying nothing would hide that someone touched
        # it, so it gets a note instead.
        if latest["status"] in BLOCKING:
            note = f"a later re-run of {latest['name']} was {latest['status']}"
    elif latest["status"] in BLOCKING:
        verdict, at = latest["status"], latest["name"]
        note, sid = latest["note"], latest["session_id"]
    else:
        verdict, at = "paused", latest["name"]
        if latest["name"] == "implement" and tasks["open"]:
            note = f"{tasks['open']} of {tasks['total']} task(s) still open after the last implement pass"
        else:
            note = f"stopped after {latest['name']}"
    # Every row gets a session to resume, not only the stuck ones. After a
    # reboot the question is "where was that conversation", whatever the
    # verdict. The phase that ran last is the one with the newest context.
    if not sid and latest:
        sid = latest["session_id"]

    try:
        mtime = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.path.getmtime(state_path)))
    except OSError:
        mtime = None
    updated = _ts(*[p["finished_at"] for p in phases], *[p["started_at"] for p in phases],
                  st.get("created_at")) or mtime

    return {
        "kind": "pipeline",
        "project": project,
        "checkout": checkout,
        "feature": feature,
        "feature_rel": rel,
        "branch": st.get("branch") or "",
        "description": (st.get("description") or "")[:400],
        "created_at": st.get("created_at"),
        "updated_at": updated,
        "cost": round(sum(p["cost"] for p in phases), 2),
        "phases": phases,
        "tasks": tasks,
        "status": verdict,
        "at": at,
        "note": note,
        "session_id": sid,
        "roadmap": None,
        # What the pipeline itself says owns it (state_init, from spec-roadmap).
        "declared_roadmap": st.get("roadmap") if isinstance(st.get("roadmap"), dict) else None,
    }


def roadmap_record(state_path, checkout, project):
    st = _read_json(state_path)
    if not isinstance(st, dict):
        return None
    slug = st.get("slug") or os.path.basename(state_path).replace(".state.json", "")
    authored = _read_json(os.path.join(os.path.dirname(state_path), slug + ".json")) or {}
    recorded = st.get("entries") or {}

    # The roadmap file is what decides the order and which entries exist at
    # all. An entry that has not started has no slot in the state file, and a
    # roadmap read from state alone would look finished one entry early.
    entries = []
    for e in authored.get("entries") or []:
        es = e.get("slug") or ""
        r = recorded.get(es) or {}
        entries.append({"slug": es, "title": e.get("title") or es,
                        "status": r.get("status") or "pending",
                        "feature_dir": r.get("feature_dir") or "",
                        "branch": r.get("branch") or "", "cost": r.get("cost_usd") or 0,
                        "note": r.get("note") or "", "updated_at": r.get("updated_at")})
    known = {e["slug"] for e in entries}
    for es, r in recorded.items():
        if es not in known and isinstance(r, dict):
            entries.append({"slug": es, "title": es, "status": r.get("status") or "pending",
                            "feature_dir": r.get("feature_dir") or "", "branch": r.get("branch") or "",
                            "cost": r.get("cost_usd") or 0, "note": r.get("note") or "",
                            "updated_at": r.get("updated_at")})

    done = sum(1 for e in entries if e["status"] == "done")
    current = next((e for e in entries if e["status"] != "done"), None)
    status = "complete" if current is None else current["status"]
    return {
        "kind": "roadmap",
        "project": project,
        "checkout": checkout,
        "slug": slug,
        "goal": authored.get("goal") or "",
        "entries": entries,
        "done": done,
        "total": len(entries),
        "current": current["slug"] if current else None,
        "status": status,
        "cost": round(sum(e["cost"] for e in entries), 2),
        "updated_at": _ts(*[e["updated_at"] for e in entries], st.get("created_at")),
    }


def transcript_index():
    """{session id: transcript path} for every Claude Code transcript on disk.

    Indexing all of them takes about 8 ms (2,233 files, measured), so it is
    rebuilt on every refresh instead of cached. A cache would miss the session
    a phase started a second ago.
    """
    base = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                        "projects")
    idx = {}
    try:
        dirs = list(os.scandir(base))
    except OSError:
        return idx
    for d in dirs:
        if not d.is_dir():
            continue
        try:
            for f in os.scandir(d.path):
                if f.name.endswith(".jsonl"):
                    idx[f.name[:-6]] = f.path
        except OSError:
            pass
    return idx


_CWD_CACHE = {}


def transcript_cwd(path):
    """The directory a session ran in, from its own transcript.

    `claude --resume <id>` only finds a session from the directory it ran in,
    so a bare id is not enough to get back to it. The directory comes from the
    transcript rather than from the state file: a phase's cwd can be a
    different worktree from the one holding the feature's files. It cannot
    change once written, so it is cached per file.
    """
    if path in _CWD_CACHE:
        return _CWD_CACHE[path]
    cwd = None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i > 50:
                    break
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if isinstance(o, dict) and o.get("cwd"):
                    cwd = o["cwd"]
                    break
    except OSError:
        pass
    _CWD_CACHE[path] = cwd
    return cwd


def resume_for(sid, index, fallback_cwd):
    """How to reopen a session, or why it cannot be reopened."""
    if not sid:
        return None
    path = index.get(sid)
    if not path:
        # Claude Code prunes old transcripts. Saying so beats offering a
        # command that fails with "No conversation found".
        return {"session_id": sid, "text": None, "reason": "transcript no longer on disk"}
    cwd = transcript_cwd(path) or fallback_cwd
    return {"session_id": sid, "cwd": cwd,
            "text": f"cd {_q(cwd)} && claude --resume {_q(sid)}", "reason": None}


def commands_for_pipeline(p):
    cd = f"cd {_q(p['checkout'])} && "
    resume = f"spec-run --resume --feature-dir {_q(p['feature_rel'])}"
    restart = cd + resume
    rm = p.get("roadmap")
    # A roadmap entry resumes through spec-roadmap. Running spec-run on it
    # directly would finish the feature but skip the roadmap's merge gate, and
    # the roadmap would still think the entry was in progress. It runs from
    # the checkout holding the roadmap's newest state, which is not always the
    # worktree the feature's files happen to be in.
    if rm and rm.get("current"):
        resume = f"spec-roadmap run {_q(rm['slug'])}"
        restart = f"cd {_q(rm['checkout'])} && {resume}"
    cmds = []
    if p["status"] in ("crashed", "interrupted", "failed", "needs_input", "paused", "limited"):
        cmds.append({"label": "Copy restart", "text": restart})

    why = {
        "crashed": f"its {p['at']} phase was killed mid-run (the runner process is gone)",
        "interrupted": f"its {p['at']} phase was interrupted before it finished",
        "failed": f"its {p['at']} phase failed: {p['note']}" if p["note"] else f"its {p['at']} phase failed",
        "needs_input": f"its {p['at']} phase stopped to ask a question: {p['note']}",
        "paused": p["note"] if p["at"] else "no phase has run yet",
        "limited": f"its {p['at']} phase was stopped by the Claude usage limit ({p['note']})",
    }.get(p["status"])
    prompt = None
    if why:
        prompt = (
            f"In {p['checkout']}, the spec-run pipeline for {p['feature']} has stopped: {why}. "
            f"Read {p['feature_rel']}/.pipeline/state.json and the phase's result file in that directory, "
            f"and work out why it stopped. If something needs fixing or answering first, do that, "
            f"and ask me if the answer is mine to give. Then resume it with `{restart}`, run it in "
            f"the background, watch it until it finishes or stops again, and tell me the outcome."
        )
    return cmds, prompt


def commands_for_roadmap(r):
    if r["status"] == "complete":
        return [], None
    run = f"spec-roadmap run {_q(r['slug'])}"
    show = {"label": "Copy show", "text": f"cd {_q(r['checkout'])} && spec-roadmap show {_q(r['slug'])}"}
    # While its runner is up, `run` would start a second runner on the same
    # roadmap. Only `show` is offered until it stops.
    if r["status"] == "running":
        return [show], None
    cmds = [{"label": "Copy run", "text": f"cd {_q(r['checkout'])} && {run}"}, show]
    cur = next((e for e in r["entries"] if e["slug"] == r["current"]), None)
    where = f" Entry {r['done'] + 1} of {r['total']}, `{cur['slug']}`, is {cur['status']}." if cur else ""
    prompt = (
        f"In {r['checkout']}, the roadmap `{r['slug']}` is {r['done']} of {r['total']} entries done.{where} "
        f"Run `spec-roadmap show {r['slug']}` to confirm where it stands. If the current entry stopped, "
        f"read its feature's .pipeline/state.json to find out why, and deal with that first. Then continue it "
        f"with `{run}` in the background, watch it, and tell me when it needs me or has finished."
    )
    return cmds, prompt


class Collector:
    def __init__(self, roots):
        self.roots = roots
        self._repos, self._at = [], 0.0
        self._lock = threading.Lock()

    def checkouts(self):
        with self._lock:
            if time.time() - self._at > DISCOVERY_TTL:
                self._repos = [(c, *_project_of(c)) for c in discover(self.roots)]
                self._at = time.time()
            return list(self._repos)

    def collect(self):
        transcripts = transcript_index()
        pipelines, roadmaps = {}, {}
        projects = {}
        states = []
        for checkout, project, project_path in self.checkouts():
            specs = os.path.join(checkout, "specs")
            try:
                features = os.listdir(specs)
            except OSError:
                features = []
            for f in features:
                sp = os.path.join(specs, f, ".pipeline", "state.json")
                if os.path.isfile(sp):
                    states.append((sp, checkout, project, project_path))
        # Only the pids recorded against a `running` phase need checking. The
        # state files are cached, so reading them twice costs nothing.
        pids = set()
        for sp, *_ in states:
            st = _read_json(sp)
            for ph in ((st or {}).get("phases") or {}).values():
                if isinstance(ph, dict) and ph.get("status") == "running":
                    try:
                        pids.add(int(ph.get("runner_pid")))
                    except (TypeError, ValueError):
                        pass
        table = runner_table(pids)

        for sp, checkout, project, project_path in states:
            rec = pipeline_record(sp, checkout, project, table)
            if not rec:
                continue
            rec["project_path"] = project_path
            # The same feature can be on disk in two worktrees of one
            # project. Keep the copy that moved most recently, because
            # that is where the work is.
            key = (project_path, rec["feature"])
            old = pipelines.get(key)
            if old is None or (rec["updated_at"] or "") > (old["updated_at"] or ""):
                pipelines[key] = rec

        for checkout, project, project_path in self.checkouts():
            projects.setdefault(project_path, project)
            rdir = os.path.join(checkout, ".specify", "roadmaps")
            try:
                rfiles = [n for n in os.listdir(rdir) if n.endswith(".state.json")]
            except OSError:
                rfiles = []
            for n in rfiles:
                rec = roadmap_record(os.path.join(rdir, n), checkout, project)
                if not rec:
                    continue
                rec["project_path"] = project_path
                # Roadmap state files are often committed, so every worktree
                # has a copy. Only the copy the runner last wrote is current.
                key = (project_path, rec["slug"])
                old = roadmaps.get(key)
                if old is None or (rec["updated_at"] or "") > (old["updated_at"] or ""):
                    roadmaps[key] = rec

        # Tie each pipeline to the roadmap entry that created it.
        def link(r, e, p, inferred):
            p["roadmap"] = {"slug": r["slug"], "entry": e["slug"], "entry_status": e["status"],
                            "current": e["slug"] == r["current"], "checkout": r["checkout"],
                            "inferred": inferred}
            # A roadmap entry that is `done` has landed on the base branch,
            # and that outranks anything the pipeline recorded before it did.
            # Seen on docket: all 10 entries merged, 9 of their pipelines still
            # ending at `review: needs_input`. The findings were fixed and
            # merged by hand, and nothing re-ran review afterwards, so the
            # pipeline's record stopped at the verdict from before the fix.
            # The old verdict stays in the note so it isn't hidden.
            if e["status"] == "done" and p["status"] != "complete":
                was = f"{p['at']} {p['status'].replace('_', ' ')}" if p["at"] else p["status"]
                p["status"], p["landed"] = "complete", True
                p["note"] = f"landed via roadmap {r['slug']}; the pipeline's last record was {was}"
            e["pipeline_status"] = p["status"]
            e["pipeline"] = p["feature"]
            if e["slug"] == r["current"]:
                r["current_pipeline"] = p["feature"]
            # A roadmap whose current entry's pipeline is running is running
            # too. `in_progress` alone could mean either running or abandoned
            # weeks ago.
            if e["slug"] == r["current"] and r["status"] == "in_progress":
                r["status"] = {"running": "running", "crashed": "crashed",
                               "unknown": "unknown"}.get(p["status"], "stopped")

        for r in roadmaps.values():
            for e in r["entries"]:
                if not e["feature_dir"]:
                    continue
                p = pipelines.get((r["project_path"], os.path.basename(e["feature_dir"].rstrip("/"))))
                if p:
                    link(r, e, p, False)

        # The pipeline's own record of its owner, written when it was created.
        # Exact, and present from the first second of the run.
        for p in pipelines.values():
            d = p["declared_roadmap"]
            if p["roadmap"] or not d:
                continue
            r = roadmaps.get((p["project_path"], d.get("slug")))
            e = r and next((e for e in r["entries"] if e["slug"] == d.get("entry")), None)
            if e and not e.get("pipeline"):
                link(r, e, p, False)

        # FALLBACK, for runs started before pipelines recorded their owner.
        # spec-roadmap records an entry's feature only after spec-run returns,
        # so for the whole of an entry's FIRST run its slot says
        # `in_progress` with no feature. That is the run you most want to see
        # tied to its roadmap. Seen live: entry 6 of 7 in_progress since
        # 10:33:32, feature_dir null, while 430-year-end-runway (created
        # 10:49:42, same worktree) ran with no roadmap shown beside it.
        # Inferred link: the first pipeline created in the roadmap's own
        # checkout after the entry started that no other entry claims.
        for r in roadmaps.values():
            cur = next((e for e in r["entries"] if e["slug"] == r["current"]), None)
            if not cur or cur["status"] != "in_progress" or cur["feature_dir"] or not cur["updated_at"]:
                continue
            cands = [p for p in pipelines.values()
                     if p["checkout"] == r["checkout"] and not p["roadmap"]
                     and (p["created_at"] or "") >= cur["updated_at"]]
            if cands:
                link(r, cur, min(cands, key=lambda p: p["created_at"]), True)

        for p in pipelines.values():
            p["commands"], p["prompt"] = commands_for_pipeline(p)
            p["resume"] = resume_for(p["session_id"], transcripts, p["checkout"])
        for r in roadmaps.values():
            r["commands"], r["prompt"] = commands_for_roadmap(r)

        groups = {}
        for path, name in projects.items():
            groups[path] = {"name": name, "path": path, "pipelines": [], "roadmaps": []}
        for p in pipelines.values():
            groups[p["project_path"]]["pipelines"].append(p)
        for r in roadmaps.values():
            groups[r["project_path"]]["roadmaps"].append(r)
        out = [g for g in groups.values() if g["pipelines"] or g["roadmaps"]]
        for g in out:
            g["pipelines"].sort(key=lambda p: p["updated_at"] or "", reverse=True)
            g["roadmaps"].sort(key=lambda r: r["updated_at"] or "", reverse=True)
            g["updated_at"] = _ts(*[p["updated_at"] for p in g["pipelines"]],
                                  *[r["updated_at"] for r in g["roadmaps"]])
        out.sort(key=lambda g: g["updated_at"] or "", reverse=True)
        return {
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "roots": self.roots,
            "process_table": table is not None,
            "projects": out,
        }


def _is_dashboard(url):
    """Is what answers at `url` a spec-dashboard? Checked by the shape of its API."""
    import urllib.request
    try:
        with urllib.request.urlopen(url + "/api/pipelines", timeout=10) as r:
            return "projects" in json.load(r)
    except Exception:
        return False


def serve(collector, port, open_browser):
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, body, ctype):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            # Loopback alone does not stop DNS rebinding: a page on any site can
            # point a hostname at 127.0.0.1 and read what this serves, which is
            # every repository path and the start of every spec. Checking the
            # Host header closes that.
            if self.headers.get("Host") not in allowed_hosts:
                return self._send(403, b"forbidden\n", "text/plain")
            path = self.path.split("?", 1)[0]
            if path == "/api/pipelines":
                try:
                    body = json.dumps(collector.collect()).encode()
                except Exception as e:  # report the failure on the page, not just in a log
                    return self._send(500, json.dumps({"error": str(e)}).encode(), "application/json")
                return self._send(200, body, "application/json")
            if path in ("/", "/index.html"):
                with open(PAGE, "rb") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            return self._send(404, b"not found\n", "text/plain")

    url = f"http://127.0.0.1:{port}"

    def launch():
        opener = "open" if sys.platform == "darwin" else "xdg-open"
        try:
            subprocess.Popen([opener, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            print(f"! could not run {opener}; open {url} yourself", file=sys.stderr)

    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError as e:
        # A dashboard that is already up is the common case, not an error:
        # `spec-dashboard --open` should mean "show it to me" however many times
        # it is typed. Only a port held by something else is a failure.
        if _is_dashboard(url):
            print(f"spec-dashboard is already running on {url}")
            if open_browser:
                launch()
            return 0
        print(f"x could not bind 127.0.0.1:{port} — {e.strerror}", file=sys.stderr)
        print("  something other than spec-dashboard holds that port; pass --port", file=sys.stderr)
        return 1
    print(f"spec-dashboard on {url}  (watching {', '.join(collector.roots)}; Ctrl-C to stop)")
    if open_browser:
        launch()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="spec-dashboard", add_help=False)
    ap.add_argument("--root", action="append", default=[])
    ap.add_argument("--port", type=int, default=8788)
    ap.add_argument("--open", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    roots = [os.path.abspath(os.path.expanduser(r)) for r in a.root] or [os.path.expanduser("~/code")]
    c = Collector(roots)
    if a.json:
        json.dump(c.collect(), sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    return serve(c, a.port, a.open)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
