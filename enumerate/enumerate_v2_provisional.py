#!/usr/bin/env python3
"""
PROVISIONAL V2 - self-running algorithm enumeration, no LLM, standard library only.
Built 2026-11-01 as the extension of enumerate_v1_provisional.py. Not John's final spec.

V1 left four things open. V2 closes each with what is already in this workspace:
  1. "Score transforms do not discriminate"  -> correction scenarios put two candidates at one address
     (teacher corrects student, as in SUNZI knowledge.zig), so SCORE decides the outcome.
  2. "label_first_last passes only because of the sentence shape" -> surface-form and distractor-edge
     scenarios; facts are typed triples (subject, relation, object) as in SUNZI / SRG / RDLA.
  3. "Where do math transformations live?" -> they now sit in three places at once: the SCORE slot
     (transforms of age / count / speaker), the representation itself (SUNZI's CRT integers, THE
     WORD's phi/tau/Fibonacci/Tribonacci hash addresses, MAP hypervector bundles with decay), and the
     update policy. The enumeration reports which placements matter.
  4. "different representations of math" -> ADDRESS fillers are SUNZI (M, K) in two layouts, the ten
     THE WORD geometric hashes, hypervector bundles, and V1's symbolic dict.

Slots enumerated: LABEL x ADDRESS(store) x UPDATE(policy) x WALK x SCORE.
Pass = every instance (chain x2, inherit x2, correction x2, surface, novel relation word; three generated
vocabularies each; plus V1's two literal scenarios) answers correctly before teaching, after teaching,
and after unrelated teaching. A tie between two different answers counts as a failure.

Run: python3 enumerate_v2_provisional.py     (no arguments; writes results_v2_provisional.toml next to itself)
"""

import hashlib
import os
import time

from v2_labelers import LABELERS
from v2_math import HASH_NAMES, hash_word
from v2_scenarios import all_instances, legacy_instances, FAMILIES, VOCABS
from v2_slots import SCORES, WALKS, harvest, walk_name, NeedScore
from v2_search import run_search
from v2_stores import STORE_NAMES, POLICIES, get_store

HERE = os.path.dirname(os.path.abspath(__file__))
NW, NS = len(WALKS), len(SCORES)


def prepare(instances):
    prep = {}
    for L in LABELERS:
        rows = []
        for inst in instances:
            lab = L()
            lab.fit([s for s, _ in inst["known"]])
            lab_all = lambda items: tuple(f for f in (lab.label(s, sp) for s, sp in items) if f is not None)
            p0 = lab_all(inst["known"])
            p1 = p0 + lab_all(inst["new"])
            p2 = p1 + lab_all(inst["control"])
            op = inst["q"][1]
            rows.append((p0, p1, p2, lab.qrel(op), lab.qrel("is"), op == "is"))
        prep[L.name] = rows
    return prep


def run_cell(rows, instances, store_name, policy, memo):
    """Passes per (walk, score) for one (labeler, store, policy). A score only matters where a pick
    has two candidates; where it never does, the walk's result is shared by all 60 scores."""
    base, vec = [0] * NW, [[0] * NS for _ in range(NW)]
    for inst, (p0, p1, p2, qrel, crel, is_chain) in zip(instances, rows):
        stores = [get_store(memo, store_name, policy, p) for p in (p0, p1, p2)]
        subj, want = inst["q"][0], (inst["before"], inst["after"], inst["after"])
        for wi, w in enumerate(WALKS):
            try:
                got = tuple(harvest(st, subj, qrel, crel, is_chain, w, None) for st in stores)
            except NeedScore:
                for si, (_, sc) in enumerate(SCORES):
                    got = tuple(harvest(st, subj, qrel, crel, is_chain, w, sc) for st in stores)
                    vec[wi][si] += got == want
                continue
            base[wi] += got == want
    return base, vec


def address_report(prep):
    """How usable is each THE WORD hash as an address on the words the instances actually store?"""
    sets = [sorted({w for f in row[2] for w in (f.s, f.o)}) for row in prep["label_ops_adaptive"]]
    every = sorted({w for s in sets for w in s})
    lines = [f"[address] THE WORD hashes (16-bit space) on the subjects/objects of the {len(sets)} instances "
             f"({len(every)} distinct words):"]
    for m, name in enumerate(HASH_NAMES):
        pairs = hit = 0
        for words in sets:
            by = {}
            for w in words:
                by.setdefault(hash_word(w, m), []).append(w)
            c = sum(len(v) * (len(v) - 1) // 2 for v in by.values())
            pairs, hit = pairs + c, hit + (c > 0)
        lines.append(f"  {m} {name:13s} distinct addresses {len({hash_word(w, m) for w in every}):4d}/{len(every)};"
                     f" instances with a collision {hit:2d}/{len(sets)}; colliding pairs {pairs}")
    return lines


def explain(prep, instances, lab, store, pol, wi, si):
    memo, bad = {}, []
    for inst, (p0, p1, p2, qrel, crel, is_chain) in zip(instances, prep[lab]):
        stores = [get_store(memo, store, pol, p) for p in (p0, p1, p2)]
        got = tuple(harvest(st, inst["q"][0], qrel, crel, is_chain, WALKS[wi], SCORES[si][1]) for st in stores)
        if got != (inst["before"], inst["after"], inst["after"]):
            bad.append(inst["name"].split("#")[0])
    return sorted(set(bad)), len(bad)


def main():
    t0 = time.time()
    instances = all_instances()
    n_inst = len(instances)
    prep = prepare(instances)
    lab_names = [L.name for L in LABELERS]
    cells = {}
    for st in STORE_NAMES:
        for pol in POLICIES:
            memo = {}
            for ln in lab_names:
                cells[(ln, st, pol)] = run_cell(prep[ln], instances, st, pol, memo)

    digest = hashlib.sha256()
    total = full = 0
    marg = {k: {} for k in ("label", "store", "update", "walk", "score")}
    best = {}
    recipes = []
    for ln in lab_names:
        for st in STORE_NAMES:
            for pol in POLICIES:
                base, vec = cells[(ln, st, pol)]
                for wi in range(NW):
                    wn, hits = walk_name(WALKS[wi]), 0
                    for si in range(NS):
                        n = base[wi] + vec[wi][si]
                        total += 1
                        digest.update(f"{ln}|{st}|{pol}|{wi}|{si}|{n}\n".encode())
                        if n > best.get(st, (-1,))[0]:
                            best[st] = (n, ln, pol, wi, si)
                        if n == n_inst:
                            full += 1
                            hits += 1
                            for k, v in (("label", ln), ("store", st), ("update", pol), ("walk", wn), ("score", SCORES[si][0])):
                                marg[k][v] = marg[k].get(v, 0) + 1
                    if hits:
                        recipes.append((ln, st, pol, wn, hits))

    print("PROVISIONAL V2 - algorithm enumeration, self-running, no LLM")
    print(f"Instances: {n_inst} (V1 literal 2 + {len(FAMILIES)} families x {VOCABS} vocabularies), each checked before / after / control")
    print(f"Slots: LABEL {len(LABELERS)} x STORE {len(STORE_NAMES)} x UPDATE {len(POLICIES)} x WALK {NW} x SCORE {NS}")
    print(f"Combinations tried: {total}   fully passing: {full}   elapsed: {time.time() - t0:.1f}s")
    print(f"Result digest (sha256, first 16): {digest.hexdigest()[:16]}")
    print()

    sizes = {"label": len(LABELERS), "store": len(STORE_NAMES), "update": len(POLICIES), "walk": NW, "score": NS}
    names = {"label": lab_names, "store": STORE_NAMES, "update": POLICIES,
             "walk": [walk_name(w) for w in WALKS], "score": [s for s, _ in SCORES]}
    for k in ("label", "store", "update", "walk", "score"):
        per = total // sizes[k]
        print(f"[{k}] fully passing combinations containing each filler (of {per}):")
        dead = [n for n in names[k] if not marg[k].get(n)]
        shown = [n for n in names[k] if marg[k].get(n)]
        if k == "score" and len(shown) > 12:
            shown = sorted(shown, key=lambda n: -marg[k][n])[:12]
            print("  (top 12 of those that pass)")
        for n in shown:
            print(f"  {n:34s} {marg[k][n]:7d}  {100.0 * marg[k][n] / per:5.1f}%")
        print(f"  dead (0 passes): {len(dead)} of {len(names[k])}" + (f" -> {', '.join(dead)}" if 0 < len(dead) <= 8 else ""))
        print()

    print("[ceiling] best instances passed by any combination of each store (of %d):" % n_inst)
    ceilings = []
    for st in STORE_NAMES:
        n, ln, pol, wi, si = best[st]
        bad, nbad = explain(prep, instances, ln, st, pol, wi, si)
        ceilings.append((st, n, ln, pol, wi, si, bad))
        print(f"  {st:20s} {n:3d}/{n_inst}  via {ln}, {pol}, {walk_name(WALKS[wi])}, {SCORES[si][0]}"
              + (f"   fails: {', '.join(bad)}" if bad else ""))
    print()

    print("\n".join(address_report(prep)))
    print()

    wi = WALKS.index((5, True, True))
    for ref in (("label_ops_adaptive", "dict", "append"), ("label_ops_adaptive", "map", "append")):
        b, v = cells[ref]
        bad = [SCORES[si][0] for si in range(NS) if b[wi] + v[wi][si] != n_inst]
        print(f"[score, no replacement] {ref[1]} + {ref[0]} + append + depth5|typed|inherit: "
              f"{NS - len(bad)} of {NS} SCORE fillers pass; failing: "
              f"{'all' if len(bad) == NS else ', '.join(bad) if bad else 'none'}")
    print()

    search_lines, search = run_search(prep, instances)
    print("\n".join(search_lines))
    print()

    print("[V1 continuity] V1 scenarios only, dict + listed labels + append, typed walk with inherit:")
    leg = legacy_instances()
    lp = prepare(leg)
    b, v = run_cell(lp["label_ops_listed"], leg, "dict", "append", {})
    row = ["pass" if b[WALKS.index((d, True, True))] == len(leg) else "fail" for d in (1, 2, 3, 4)]
    print(f"  depth 1..4 -> {' '.join(row)}   (V1: direct, chain1 fail; chain2, chain3 pass)")
    assert row == ["fail", "fail", "pass", "pass"], "V1 continuity broken"
    print()

    print("[recipes] per store: update policies and labelers that pass, and (walk, score) pairs that pass:")
    agg = {}
    for ln, st, pol, wn, hits in recipes:
        a = agg.setdefault((ln, st, pol), [0, []])
        a[0] += hits
        a[1].append(wn)
    for st in STORE_NAMES:
        rows = [(k, v) for k, v in agg.items() if k[1] == st]
        if rows:
            pols = ", ".join(f"{p} {sum(v[0] for k, v in rows if k[2] == p) // len(set(k[0] for k, _ in rows if k[2] == p))}"
                             for p in POLICIES if any(k[2] == p for k, _ in rows))
            print(f"  {st:20s} labels: {', '.join(sorted(set(k[0] for k, _ in rows)))}; update (pairs per label): {pols}")
    print()

    out = os.path.join(HERE, "results_v2_provisional.toml")
    with open(out, "w", encoding="utf-8") as f:
        f.write("# PROVISIONAL V2 results, generated by running enumerate_v2_provisional.py,\n")
        f.write("# no LLM, synthetic toy data only.\n")
        f.write(f"instances = {n_inst}\ntotal_combinations = {total}\npassing_combinations = {full}\n")
        f.write(f"digest = \"{digest.hexdigest()[:16]}\"\n\n")
        f.write(f"[search]\nexpressions = {search['total']}\npassing = {search['passed']}\n")
        f.write(f"score_deciding_instances = {search['live_instances']}\n\n")
        for st, n, ln, pol, wi, si, bad in ceilings:
            f.write(f"[[ceiling]]\nstore = \"{st}\"\nbest_instances = {n}\nlabel = \"{ln}\"\nupdate = \"{pol}\"\n")
            f.write(f"walk = \"{walk_name(WALKS[wi])}\"\nscore = \"{SCORES[si][0]}\"\nfails = \"{', '.join(bad)}\"\n\n")
        for (ln, st, pol), (hits, walks) in agg.items():
            f.write(f"[[passing]]\nlabel = \"{ln}\"\nstore = \"{st}\"\nupdate = \"{pol}\"\npairs = {hits}\n")
            f.write(f"walks = \"{', '.join(sorted(set(walks)))}\"\n\n")
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
