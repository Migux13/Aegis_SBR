"""Read the AegisProbe SavedVariable and summarise it.

The 1.12 client has no file access, so Aegis collects ClassicAPI verification
data into a SavedVariable that the client serialises on /reload or logout. This
parses that file so the results can be read without doing anything in game.

Usage:
    py scripts/read_probe.py                    # newest file under the default WTF tree
    py scripts/read_probe.py <path to Aegis_SBR.lua>
    py scripts/read_probe.py --all              # every character that has data
"""

import os
import re
import sys
import glob

DEFAULT_WTF = r"E:\Spiele\OctoWoW\WTF\Account"

# Entries look like:  ["12.34|Rupture cp=4 dur=14.0 rest=13.4"] or  "12.34|..."
ENTRY = re.compile(r'"(\d+\.\d+)\|([^"]*)"')


def find_files(root):
    return glob.glob(os.path.join(root, "*", "*", "*", "SavedVariables", "Aegis_SBR.lua"))


def slice_probe(text):
    """Return just the AegisProbe assignment, or None."""
    i = text.find("AegisProbe = {")
    if i < 0:
        return None
    # Brace-match from the opening brace so a later SavedVariable cannot bleed in.
    start = text.index("{", i)
    depth, j = 0, start
    while j < len(text):
        c = text[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
        j += 1
    return text[start:]


def parse(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    blob = slice_probe(text)
    if not blob:
        return None
    meta = {}
    for key in ("started", "class", "player", "capi"):
        m = re.search(r'\["?%s"?\]\s*=\s*"?([^",\n]+)"?' % key, blob)
        if m:
            meta[key] = m.group(1).strip()
    # Split into categories so entries keep their bucket.
    cats = {}
    for cm in re.finditer(r'\["(\w+)"\]\s*=\s*\{', blob):
        name = cm.group(1)
        if name in ("cat", "e"):
            continue
        seg = blob[cm.end():]
        end = seg.find("\n\t\t\t},")
        rows = [(float(a), b) for a, b in ENTRY.findall(seg if end < 0 else seg[:end])]
        if rows:
            cats.setdefault(name, []).extend(rows)
    return meta, cats


def report(path):
    got = parse(path)
    if not got:
        return False
    meta, cats = got
    if not cats:
        return False
    char = os.path.basename(os.path.dirname(os.path.dirname(path)))
    print("=" * 70)
    print("%s   class=%s  ClassicAPI=%s  started=%s"
          % (char, meta.get("class", "?"), meta.get("capi", "?"), meta.get("started", "?")))
    print("=" * 70)
    for cat in sorted(cats):
        rows = sorted(cats[cat])
        print("\n-- %s (%d) --" % (cat, len(rows)))
        for t, line in rows:
            print("  %8.2f  %s" % (t, line))
        if cat == "perf":
            # The question this answers: is the addon slow, or is everything
            # slow? A high rotation cost with a low frame rate points at us; a
            # low cost with a low frame rate points anywhere else.
            fps, avg, mx, grp = [], [], [], []
            for _, l in rows:
                m = re.search(r"fps=(\d+)", l)
                if m: fps.append(int(m.group(1)))
                m = re.search(r"rot_avg=([\d.]+)ms", l)
                if m: avg.append(float(m.group(1)))
                m = re.search(r"rot_max=([\d.]+)ms", l)
                if m: mx.append(float(m.group(1)))
                m = re.search(r"group=(\d+)", l)
                if m: grp.append(int(m.group(1)))
            if fps:
                fps.sort()
                print("    frame rate   min %d  median %d  max %d"
                      % (fps[0], fps[len(fps) // 2], fps[-1]))
            if avg:
                avg.sort()
                print("    rotation     median %.2f ms per press, worst sample %.2f ms"
                      % (avg[len(avg) // 2], max(mx) if mx else 0))
            if grp:
                print("    group size   %d .. %d" % (min(grp), max(grp)))
            continue

        if cat == "range":
            # The proxy is CheckInteractDistance(3), a ~9.9yd MELEE test. Comparing
            # it against a 30yd nuke trivially "disagrees" at any range past 9.9,
            # which is not a finding - so the statistic is only emitted for melee
            # probes. Reporting it for a ranged probe produced a meaningless
            # "2 of 2 disagree" on the first warlock capture.
            melee = ("Heroic Strike", "Rend", "Sinister Strike", "Backstab",
                     "Raptor Strike", "Maul", "Claw", "Shred", "Stormstrike",
                     "Crusader Strike")
            by = {}
            for _, l in rows:
                sp = l.split(" inRange=")[0]
                by.setdefault(sp, []).append(l)
            for sp, flips in sorted(by.items()):
                odd = [l for l in flips
                       if ("inRange=true" in l and "proxy=false" in l)
                       or ("inRange=false" in l and "proxy=true" in l)]
                if sp in melee:
                    print("  => %s: %d of %d flips disagree with the 9.9yd proxy"
                          % (sp, len(odd), len(flips)))
                else:
                    print("  => %s: ranged probe, %d flips (proxy comparison N/A "
                          "- it is a melee test)" % (sp, len(flips)))
    print()
    return True


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    every = "--all" in sys.argv
    if args:
        files = args
    else:
        files = find_files(DEFAULT_WTF)
        files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
        if not every:
            files = files[:6]
    if not files:
        print("no SavedVariables found under", DEFAULT_WTF)
        return
    any_data = False
    for f in files:
        try:
            if report(f):
                any_data = True
        except Exception as exc:                      # noqa: BLE001 - diagnostics
            print("could not parse %s: %s" % (f, exc))
    if not any_data:
        print("No AegisProbe data yet. Enable with /sbr probe on, play, then /reload.")


if __name__ == "__main__":
    main()
