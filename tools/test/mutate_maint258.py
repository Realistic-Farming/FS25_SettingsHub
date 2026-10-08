# MAINTENANCE row 258 mutation battery: the hub shows a selfPersisted companion's live value through its
# reader (src/SettingsHub.lua: registerModule's read, _shownValue, getValue, getModules, onWriteState,
# _readMoved and update's republish). Rows live in tools/test/lua/maint258_hub_mirror_pull_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-26, R-25a): the lines this PR changes, Bob's four (the server-only
# gate, the republish, the snap, the in-flight preference) plus the three reads the Tablet and the broadcast
# go through and the log-once. Targeted runs only (Tyson, 2026-09-30): each mutant runs SELECTED, this PR's
# bench, the one whose companions pass a reader; the two other benches that load the hub (maint217,
# maint241) ran once, unmutated, as the PR's selection baseline. This repo's runner has no selection, so the
# script writes a filtered copy of run-tests.mjs beside it for the run and deletes it after. Run ONE mutant
# per call, in the foreground, and check free memory by hand right before each (1 GB or more).
#
# The edit is proved to LAND (exact occurrence count) and the restore is proved by a hash. KILLED* means
# killed only by a Lua error or a raised group: a weak kill.
#
# NOT RUN, and why: comments; the header's usage lines; REPUBLISH_MS's value (the bench ticks past it).
#
# Usage (from the repo root):
#        py tools/test/mutate_maint258.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint258.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint258.py --baseline  the selected tests, unmutated
#        py tools/test/mutate_maint258.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HUB = "src/SettingsHub.lua"

SELECTED = [
    "maint258_hub_mirror_pull_test.lua",
]
FILTER_FROM = 'const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua")).sort();'
FILTER_TO = ('const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua") && '
             'process.env.MUTATE_SELECTED.split(",").includes(f)).sort();')

MUTATIONS = [
 ("M01-admin-read-on-client", HUB,
  [("    if def.adminOnly and not self:_isServer() then return mirror end\n", "", 1)],
  "a client reads its own companion for an admin key, which may be stale (S3)"),
 ("M02-no-republish", HUB,
  [("            if self:_readMoved() then\n", "            if false then\n", 1)],
  "a server change outside the hub never reaches a client's Tablet within the interval (S3)"),
 ("M03-no-snap", HUB,
  [("    if ok and raw ~= nil then v = self:_validate(def, self:_snapNetworkValue(def, raw)) end\n",
    "    if ok and raw ~= nil then v = self:_validate(def, raw) end\n", 1)],
  "the depot's float32 ratio fails the enum check and the hub shows its stale mirror (S1)"),
 ("M04-no-in-flight-preference", HUB,
  [("    if self:_hasPending(modId, key) then return mirror end\n", "", 1)],
  "a change in flight shows the companion's not-yet-applied value, so a double press steps from it (D1)"),
 ("M05-getmodules-mirror", HUB,
  [("                id = id, type = def.type, value = self:_shownValue(modId, id), default = def.default,\n",
    "                id = id, type = def.type, value = mod.values[id], default = def.default,\n", 1)],
  "the Tablet's list shows the mirror, as before (S1, L1)"),
 ("M06-broadcast-mirror", HUB,
  [("            local v = mod.defs[id].adminOnly and self:_shownValue(modId, id) or nil\n",
    "            local v = mod.defs[id].adminOnly and mod.values[id] or nil\n", 1)],
  "the broadcast sends the mirror, so clients never get the companion's value (S3)"),
 ("M07-log-every-read", HUB,
  [("        if not self.readWarned[tag] then\n", "        if true then\n", 1)],
  "a failing read logs on every read, flooding the log while the Tablet draws (F2)"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def read(rel):
    with open(p(rel), "rb") as f: return f.read()


def anchors(rel, edits):
    data = read(rel)
    crlf = b"\r\n" in data
    out = []
    for old, new, want in edits:
        o = old.encode("utf-8")
        n = new.encode("utf-8")
        if crlf:
            o = o.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            n = n.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        out.append((o, n, want, data.count(o)))
    return data, out


def run_suite():
    here = os.path.join(ROOT, "tools", "test")
    runner = open(os.path.join(here, "run-tests.mjs"), encoding="utf-8").read()
    if runner.count(FILTER_FROM) != 1:
        raise SystemExit("run-tests.mjs changed: the selection anchor is not found once")
    sel = os.path.join(here, "_mutate_selected_runner.mjs")
    with open(sel, "w", encoding="utf-8", newline="\n") as f:
        f.write(runner.replace(FILTER_FROM, FILTER_TO))
    try:
        env = dict(os.environ, MUTATE_SELECTED=",".join(SELECTED))
        r = subprocess.run(["node", "_mutate_selected_runner.mjs"], cwd=here, env=env,
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
    finally:
        os.remove(sel)
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    lines = [strip(l) for l in out.splitlines()]
    fails = [l for l in lines if l.startswith("FAIL ") or "Lua error" in l or "crashed" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:34s} {rel}  {why}")
        return 0
    if argv[0] == "--check":
        bad = 0
        for mid, rel, edits, _ in MUTATIONS:
            _, found = anchors(rel, edits)
            for i, (_, _, want, got) in enumerate(found):
                if got != want:
                    bad += 1
                    print(f"ANCHOR {mid} edit {i + 1}: want {want}, found {got}")
        print(f"{len(MUTATIONS)} mutants, {bad} bad anchor(s)")
        return 1 if bad else 0
    if argv[0] == "--baseline":
        rc, fails, out = run_suite()
        tail = [l for l in out.strip().splitlines() if l.strip()]
        print(re.sub(r"\x1b\[[0-9;]*m", "", tail[-1]) if tail else "(no output)")
        return rc
    picked = [m for m in MUTATIONS if m[0].startswith(argv[0])]
    if len(picked) != 1:
        print(f"'{argv[0]}' matches {len(picked)} mutants; name exactly one")
        return 2
    mid, rel, edits, why = picked[0]
    data, found = anchors(rel, edits)
    for i, (_, _, want, got) in enumerate(found):
        if got != want:
            print(f"{mid}: ANCHOR edit {i + 1} want {want}, found {got}; nothing changed")
            return 2
    before = sha(data)
    mutated = data
    for o, n, _, _ in found: mutated = mutated.replace(o, n)
    if mutated == data:
        print(f"{mid}: the edit changed nothing; not run")
        return 2
    try:
        with open(p(rel), "wb") as f: f.write(mutated)
        rc, fails, _ = run_suite()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertion = [f for f in fails if "Lua error" not in f and "crashed" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    shown = assertion + [f for f in fails if f not in assertion]
    for f in shown[:12]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
