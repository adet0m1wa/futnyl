"""Removes the dummy-Spotify test bench from a copy of the Rive project, so the
app's .riv carries only the vinyl (no test songs, covers or script).
Usage: python3 strip-bench.py <copy of rive/>/scene.rml
"""
import re
import sys

path = sys.argv[1]
s = open(path).read()

if "spotify test" not in s:
    print("no test bench to strip")
    sys.exit(0)


def cut(start_pat, tag):
    global s
    m = re.search(start_pat, s)
    assert m, start_pat
    i = s.rindex("\n", 0, m.start()) + 1
    depth, j = 0, m.start()
    rx = re.compile(rf"<{tag}(?:\s[^>]*)?>|</{tag}>")
    while True:
        t = rx.search(s, j)
        j = t.end()
        if t.group(0).startswith("</"):
            depth -= 1
        elif not t.group(0).endswith("/>"):
            depth += 1
        if depth == 0:
            break
    s = s[:i] + s[s.index("\n", j) + 1:]


cut(r'<Artboard [^>]*name="spotify test"', "Artboard")
cut(r'<ViewModel [^>]*name="Spotify Test"', "ViewModel")
cut(r'<ViewModelInstance [^>]*name="Bench vinyl"', "ViewModelInstance")
s = re.sub(r'\n\s*<(AudioAsset|ImageAsset) [^>]*file="test/[^"]*"[^>]*/>', "", s)
s = re.sub(r'\n\s*<ScriptAsset [^>]*file="dummySpotify.luau"[^>]*/>', "", s)
assert "test/" not in s and "dummySpotify" not in s and "spotify test" not in s
open(path, "w").write(s)
print("stripped the test bench")
