# MAINTENANCE row 217 mutation battery: SettingsHub gives a float32-carried enum value back as the
# declared option it stands for, on the two network paths (src/SettingsHub.lua: _snapNetworkValue,
# applyAdminChangeFromNetwork, onReadState). Rows live in tools/test/lua/maint217_enum_float32_snap_test.lua.
#
# TARGETED (Tyson, 2026-09-25): only the lines this PR changes. This repo's runner has no selection,
# so each mutant runs the whole suite (six small files). Run ONE mutant per call, in the foreground,
# and check free memory between calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence count) and
# the restore is proved by a hash. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why:
#   - the `def.type ~= "enum"` guard: a float or int def carries no `values` list, so the
#     `type(def.values) ~= "table"` guard beside it returns the value the same way;
#   - `bestDiff == nil or d < bestDiff` (nearest, not first): two declared options within 2^-23 of
#     each other's size would be one float32 value; no schema can tell them apart on the wire;
#   - `value ~= value` (NaN): math.abs(NaN) compares false with every tolerance, so NaN is returned
#     unchanged either way and the exact check refuses it (row U5);
#   - `<=` against `<` in the tolerance: it differs only at a difference of exactly zero, where the
#     exact check that follows accepts the value anyway;
#   - comments.
#
# Usage (from the repo root):
#        py tools/test/mutate_maint217.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint217.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint217.py --baseline  the suite, unmutated
#        py tools/test/mutate_maint217.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HUB = "src/SettingsHub.lua"
SELECT = {HUB: []}

MUTATIONS = [
 ("M01-server-not-snapped", HUB,
  [("    local v = self:_validate(def, self:_snapNetworkValue(def, value))\n", "    local v = self:_validate(def, value)\n", 1)],
  "the server validates the float32 value exactly, as before the fix (S3)"),
 ("M02-client-not-snapped", HUB,
  [("            local v = self:_validate(mod.defs[key], self:_snapNetworkValue(mod.defs[key], value))\n",
    "            local v = self:_validate(mod.defs[key], value)\n", 1)],
  "the client validates the carried value exactly, as before the fix (C3)"),
 ("M03-tolerance-wide", HUB,
  [("SettingsHub.FLOAT32_REL = 2 ^ -23\n", "SettingsHub.FLOAT32_REL = 2 ^ -10\n", 1)],
  "a value ten float32 steps from 0.8 is taken as 0.8 (S6)"),
 ("M04-tolerance-absolute", HUB,
  [("            if d <= math.abs(option) * SettingsHub.FLOAT32_REL and (bestDiff == nil or d < bestDiff) then\n",
    "            if d <= SettingsHub.FLOAT32_REL and (bestDiff == nil or d < bestDiff) then\n", 1)],
  "the tolerance ignores the option's size, so a tiny number is taken as the option 0 (U1)"),
 ("M05-no-number-guard", HUB,
  [("    if type(value) ~= \"number\" or value ~= value then return value end\n", "", 1)],
  "a string or boolean value reaches math.abs (U2, U3)"),
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


def run_selection(select):
    r = subprocess.run(["node", "run-tests.mjs"] + select, cwd=os.path.join(ROOT, "tools", "test"),
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
        worst = 0
        for rel in (HUB,):
            rc, fails, out = run_selection(SELECT[rel])
            tail = [l for l in out.strip().splitlines() if l.strip()]
            print(rel + ": " + (re.sub(r"\x1b\[[0-9;]*m", "", tail[-1]) if tail else "(no output)"))
            worst = max(worst, rc)
        return worst
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
        rc, fails, _ = run_selection(SELECT[rel])
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertion = [f for f in fails if "Lua error" not in f and "group raised" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    # Assertion failures first: a kill is attributed to a row, not to a crash elsewhere.
    shown = assertion + [f for f in fails if f not in assertion]
    for f in shown[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
