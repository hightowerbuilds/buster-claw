#!/usr/bin/env python3
"""Reference scan: public functions with no caller outside their own file.

CODE_QUALITY_SWEEP_10-16-26 Phase 2 gate. Run from the repo root:
    python3 -I scripts/refs_scan.py
A grep inventory is a LOWER BOUND (dead-code pass 08-09): `{__MODULE__, :fun}`
registries and `seed: {mod, fun}` entries are invisible here. Verify by hand.
Not a CI gate — HEEx components called as `<.name>` in their own file read as
in-file uses, and the script does not model dynamic dispatch."""
import re, os, collections
root="lib"
files=[os.path.join(d,f) for d,_,fs in os.walk(root) for f in fs if f.endswith(".ex")]
src={f:open(f).read() for f in files}
test="\n".join(open(os.path.join(d,f)).read() for d,_,fs in os.walk("test") for f in fs if f.endswith(".exs"))
other="\n".join(open(os.path.join(d,f),errors="ignore").read() for top in ["config","priv/repo","scripts","desktop/tauri/src","assets/js"] if os.path.isdir(top) for d,_,fs in os.walk(top) for f in fs if f.endswith((".exs",".ex",".rs",".js",".sh")))
common=set("new get put list delete update create read save run start stop init handle_event handle_info handle_call handle_cast handle_continue mount render terminate child_spec start_link to_string inspect format config_change update_params".split())
def used(name, text):
    n=re.escape(name)
    # call, capture, keyword/atom reference, pipe target
    return re.search(r"(?<![\w.:])"+n+r"\s*\(", text) or re.search(r"&[\w.]*\."+n+r"/\d", text) or re.search(r"\."+n+r"(?![\w?!])", text) or re.search(r":"+n+r"(?![\w?!])", text)
out=collections.OrderedDict()
for f,s in src.items():
    names=sorted(set(re.findall(r"^\s*def\s+([a-z_][\w?!]*)", s, re.M)))
    others="\n".join(v for k,v in src.items() if k!=f)
    for n in names:
        if n in common or n.startswith("__"): continue
        if used(n, others): continue
        t=bool(used(n,test)); x=bool(used(n,other))
        out.setdefault(f,[]).append(n+("(T)" if t else "")+("(X)" if x else ""))
zero=[(f,n) for f,ns in out.items() for n in ns if "(T)" not in n and "(X)" not in n]
tonly=[(f,n) for f,ns in out.items() for n in ns if "(T)" in n and "(X)" not in n]
print("## ZERO callers anywhere (lib, test, config, scripts, js, rust):", len(zero))
for f,n in zero: print(f"{f}: {n}")
print("\n## TEST-ONLY callers:", len(tonly))
for f,n in tonly: print(f"{f}: {n}")
