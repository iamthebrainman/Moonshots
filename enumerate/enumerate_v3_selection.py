#!/usr/bin/env python3
"""
PROVISIONAL V3 - selection for the multi-scale whole-word path RTN, self-running, no LLM,
standard library only. Built 2026-11-03 on the V1/V2 enumeration idea. Not John's final spec.

How it selects: the architecture sketch is not matched by its parts but by its claims. Each claim
is a mechanical probe (v3_probes.py) that trains a net from nested text files of made-up words
(v3_corpora.py) and reads the graph or walks it. Each mechanism in the sketch is a slot with
alternatives (v3_net.py): scales 0/1/2, recursion off/on, plasticity none/merge/merge+split,
maintenance signal none/count/external/intrinsic (horizon, tolerance, transform), staging off/on.
A configuration is selected when every probe passes and the integration probe (one net, every
corpus, full configuration) passes. Then each slot is flipped one value at a time from a selected
configuration to show which probe breaks, i.e. what each part is for.

Run: python3 enumerate_v3_selection.py     (no arguments; writes results_v3_selection.toml)
"""

import hashlib
import itertools
import os
import time

from v3_probes import PROBES, Env, run_integration, run_probe

HERE = os.path.dirname(os.path.abspath(__file__))

CLAIMS = {
    "grow": "no frozen vocabulary: starts empty, new word = new state",
    "phrase": "stabilised phrase is one node, completes a walk, expands back",
    "topic": "a hub keeps a walk on topic across a run shared by both topics",
    "recur": "nesting deeper than trained is accepted, unbalanced refused",
    "merge": "interchangeable words fuse, different words stay apart",
    "split": "a two-sense word splits, each sense keeps its continuations",
    "prune": "redundant stray arcs go; no dead end, no stranded state",
    "stage": "burst never a phrase, stable phrase kept, no fusion on thin evidence",
    "baby": "human edits are graph updates; last-exit rejection surfaced",
}


def signal_values():
    vals = [("none", ("none",)), ("count", ("count",)), ("external", ("external",))]
    for h in (1, 2, 3, 0):
        for d, tr in ((0, "count"), (0.05, "count"), (0.05, "log")):
            vals.append((f"intr(h={h or 'inf'},d={d},{tr})", ("intr", h, d, tr)))
    return vals


SLOTS = {
    "scales": [("s0", 0), ("s01", 1), ("s012", 2)],
    "recursion": [("off", False), ("on", True)],
    "plasticity": [("none", "none"), ("merge", "merge"), ("merge+split", "merge+split")],
    "signal": signal_values(),
    "staging": [("off", False), ("on", True)],
}


class Runner:
    def __init__(self, env):
        self.env, self.iso, self.integ = env, {}, {}

    def slots(self, names):
        return {k: dict(SLOTS[k])[names[k]] for k in SLOTS}

    def evaluate(self, names):
        s = self.slots(names)
        res = {}
        for p in PROBES:
            key = (p[0],) + tuple(s[k] for k in p[1])
            if key not in self.iso:
                self.iso[key] = run_probe(self.env, p, s)
            res[p[0]] = self.iso[key]
        if all(ok for ok, _ in res.values()):
            key = tuple(s[k] for k in SLOTS)
            if key not in self.integ:
                self.integ[key] = run_integration(self.env, s)
            res["integration"] = self.integ[key]
        else:
            res["integration"] = (False, "not run")
        return res


def main():
    t0 = time.time()
    env = Env(os.path.join(HERE, "v3_corpora"))
    run = Runner(env)
    names_by_slot = {k: [n for n, _ in v] for k, v in SLOTS.items()}
    total = 1
    for v in names_by_slot.values():
        total *= len(v)

    digest, selected, per_probe = hashlib.sha256(), [], {p[0]: 0 for p in PROBES}
    for combo in itertools.product(*names_by_slot.values()):
        names = dict(zip(names_by_slot, combo))
        res = run.evaluate(names)
        digest.update((repr(combo) + repr(sorted((k, v[0]) for k, v in res.items())) + "\n").encode())
        for p in PROBES:
            per_probe[p[0]] += res[p[0]][0]
        if all(ok for ok, _ in res.values()):
            selected.append(names)

    print("PROVISIONAL V3 - selection for the multi-scale whole-word path RTN, self-running, no LLM")
    print("Slots: " + " x ".join(f"{k.upper()} {len(v)}" for k, v in SLOTS.items()) + f" = {total} configurations")
    print(f"Probes: {len(PROBES)} isolated + 1 integration; corpora written as text files under {os.path.basename(env.base)}/")
    print(f"Selected (every probe and the integration probe pass): {len(selected)} of {total}   elapsed {time.time() - t0:.1f}s")
    print(f"Result digest (sha256, first 16): {digest.hexdigest()[:16]}")
    print()

    print("[probes] configurations passing, and what each probe reads")
    for p in PROBES:
        support = ""
        deps = [k for k in p[1]]
        if deps:
            parts = []
            for k in deps:
                ok_vals = [n for n, v in SLOTS[k]
                           if any(r[0] for key, r in run.iso.items() if key[0] == p[0] and v in key[1:])]
                if len(ok_vals) < len(SLOTS[k]):
                    parts.append(f"{k} in {{{', '.join(ok_vals) if len(ok_vals) <= 4 else str(len(ok_vals)) + ' of ' + str(len(SLOTS[k]))}}}")
            support = "; needs " + ", ".join(parts) if parts else "; any value"
        print(f"  {p[0]:7s} {per_probe[p[0]]:4d}/{total}  reads {', '.join(deps) or '-':32s}{support}")
        print(f"          {CLAIMS[p[0]]}")
    print()

    if not selected:
        print("[selected] none")
        return
    print(f"[selected] {len(selected)} configurations")
    for n in selected:
        print("  " + " | ".join(f"{k}={n[k]}" for k in SLOTS))
    print()
    print("[support] fillers present in the selected set")
    for k in SLOTS:
        present = [x for x in names_by_slot[k] if any(n[k] == x for n in selected)]
        print(f"  {k:11s} {', '.join(present)}" + ("" if len(present) < len(names_by_slot[k]) else "  (all)"))
    print()

    base = selected[0]
    res = run.evaluate(base)
    print("[evidence] first selected configuration, every probe:")
    for p in PROBES:
        print(f"  {p[0]:7s} {res[p[0]][1]}")
    print(f"  {'integr.':7s} {res['integration'][1]}")
    print()

    print("[necessity] flip one slot of the first selected configuration -> probes that break")
    flips = []
    for k in SLOTS:
        row = []
        for alt in names_by_slot[k]:
            if alt == base[k]:
                continue
            r = run.evaluate(dict(base, **{k: alt}))
            failed = [n for n, (ok, _) in r.items() if not ok and not (n == "integration" and r[n][1] == "not run")]
            if not failed and not r["integration"][0]:
                failed = ["integration"]
            row.append((alt, failed))
            flips.append((k, alt, failed))
        passing = [a for a, f in row if not f]
        broken = {}
        for a, f in row:
            if f:
                broken.setdefault(",".join(f), []).append(a)
        print(f"  {k:11s} base {base[k]}; also passes: {', '.join(passing) if passing else 'none'}")
        for f, alts in broken.items():
            print(f"              {', '.join(alts) if len(alts) <= 5 else str(len(alts)) + ' values'} -> breaks {f}")
    print()

    out = os.path.join(HERE, "results_v3_selection.toml")
    with open(out, "w", encoding="utf-8") as f:
        f.write("# PROVISIONAL V3 results, generated by running enumerate_v3_selection.py,\n")
        f.write("# no LLM, synthetic text files of made-up words only.\n")
        f.write(f"configurations = {total}\nselected = {len(selected)}\ndigest = \"{digest.hexdigest()[:16]}\"\n\n")
        for n in selected:
            f.write("[[selected]]\n" + "".join(f"{k} = \"{n[k]}\"\n" for k in SLOTS) + "\n")
        for k, alt, failed in flips:
            f.write(f"[[flip]]\nslot = \"{k}\"\nvalue = \"{alt}\"\nbreaks = \"{','.join(failed)}\"\n\n")
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
