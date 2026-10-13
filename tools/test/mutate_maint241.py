# MAINTENANCE row 241 mutation battery: SettingsHub reaches NetworkSync and StateLedger through the mission
# (src/SettingsHub.lua: networkSyncHandle, stateLedgerHandle, _bindBedrock, applyAdminChangeFromNetwork's
# broadcast, deserializeAdmin's selfPersisted skip, onReadState's selfPersisted mirror (Desk's option A),
# onWriteState's nil guard (Bob's R-15 MAJOR);
# src/AdminControlRegistry.lua: networkSyncHandle, bindNetwork, invoke). Rows live in
# tools/test/lua/maint241_bedrock_binding_test.lua.
#
# TARGETED (Tyson, 2026-09-25): only the lines this PR changes. This repo's runner has no selection,
# so each mutant runs the whole suite (seven small files). Run ONE mutant per call, in the foreground,
# and check free memory between calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence count) and
# the restore is proved by a hash. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why:
#   - `self.stateLedgerBound = true` and `self.networkSyncBound = true` removed: each later call registers
#     the same hooks again, which StateLedger and NetworkSync accept as an overwrite with a warning
#     ("already registered, overwriting", StateLedger.lua:63-64, NetworkSync.lua:113-114) and StateLedger
#     delivers once per module (deliveredTo, :84-86), so nothing a player or a row sees changes;
#   - `self.bedrockBound`, now the status line's either-flag: read by no code path;
#   - the console status line's text; comments.
#
# Usage (from the repo root):
#        py tools/test/mutate_maint241.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint241.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint241.py --baseline  the suite, unmutated
#        py tools/test/mutate_maint241.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HUB = "src/SettingsHub.lua"
REG = "src/AdminControlRegistry.lua"

MUTATIONS = [
 ("M01-networksync-bare-global", HUB,
  [("    return (mission ~= nil and mission.networkSync) or g_networkSync\n", "    return g_networkSync\n", 1)],
  "the hub reads NetworkSync as a bare global again, nil in a mod environment (E1, A1)"),
 ("M02-stateledger-bare-global", HUB,
  [("    return (mission ~= nil and mission.stateLedger) or g_stateLedger\n", "    return g_stateLedger\n", 1)],
  "the hub reads StateLedger as a bare global again (E1, P1)"),
 ("M03-broadcast-bare-global", HUB,
  [("    local networkSync = SettingsHub.networkSyncHandle()\n    if networkSync ~= nil then\n",
    "    local networkSync = g_networkSync\n    if networkSync ~= nil then\n", 1)],
  "the server's broadcast after an admin change reads the bare global (A1, A2)"),
 ("M04-registry-handle-bare-global", REG,
  [("    return (mission ~= nil and mission.networkSync) or g_networkSync\n", "    return g_networkSync\n", 1)],
  "the registry reads NetworkSync as a bare global again (E3, R1)"),
 ("M05-registry-bind-bare-global", REG,
  [("    local networkSync = AdminControlRegistry.networkSyncHandle()\n    if self.actionBound or networkSync == nil then return end\n",
    "    local networkSync = g_networkSync\n    if self.actionBound or networkSync == nil then return end\n", 1)],
  "the registry binds its invoke action through the bare global (E3, R1)"),
 ("M06-registry-invoke-bare-global", REG,
  [("    local networkSync = AdminControlRegistry.networkSyncHandle()\n    if networkSync ~= nil then\n",
    "    local networkSync = g_networkSync\n    if networkSync ~= nil then\n", 1)],
  "a client's invoke reads the bare global and sends nothing (R1)"),
 ("M07-selfpersisted-clobbered", HUB,
  [("        if mod ~= nil and not mod.selfPersisted then\n", "        if mod ~= nil then\n", 1)],
  "StateLedger's delivery overwrites a selfPersisted companion with the hub's stored copy (P3)"),
 ("M08-networksync-locked-out", HUB,
  [("    if not self.networkSyncBound and networkSync ~= nil then\n",
    "    if not self.networkSyncBound and not self.stateLedgerBound and networkSync ~= nil then\n", 1)],
  "StateLedger bound first locks NetworkSync out, as one flag did before (E1, B1)"),
 ("M09-selfpersisted-onchange-on-client", HUB,
  [("                if not mod.selfPersisted then\n                    self:_queue(modId, key, v, nil)\n                end\n",
    "                self:_queue(modId, key, v, nil)\n", 1)],
  "a client calls a selfPersisted companion's onChange, against the hub's mirror contract (Desk's option A; A2)"),
 ("M10-nil-triplet-written", HUB,
  [("            if mod.defs[id].adminOnly and mod.values[id] ~= nil then\n", "            if mod.defs[id].adminOnly then\n", 1)],
  "a nil admin value leaves a hole that shifts every later triplet (Bob's R-15 MAJOR; N1)"),
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
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    lines = [strip(l) for l in out.splitlines()]
    fails = [l for l in lines if l.startswith("FAIL ") or "Lua error" in l or "group raised" in l]
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
    assertion = [f for f in fails if "Lua error" not in f and "group raised" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    shown = assertion + [f for f in fails if f not in assertion]
    for f in shown[:8]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
