#!/usr/bin/env python3
"""
PROVISIONAL V2 - stage 2: the system composes its own math transformations for the SCORE slot.
Stage 1 used a hand-listed grid of 60 score fillers. Here nothing is hand-listed beyond eight
primitives: every unary composition f(g(x)) of them is generated, applied to the age channel and
to the count channel, optionally combined with speaker authority by product or by sum, and each
generated expression is run through the correction instances (the only ones where a score decides)
in the structure stage 1 found sufficient: adaptive labels, dict, append, typed walk with inherit.
"""

import math

from v2_math import PHI
from v2_slots import harvest, NeedScore
from v2_stores import get_store

WALK = (5, True, True)
PRIMS = [("x", lambda x: x), ("log1p", math.log1p), ("sqrt", math.sqrt), ("sq", lambda x: x * x),
         ("1/(1+x)", lambda x: 1.0 / (1 + x)), ("phi^-x", lambda x: PHI ** -x),
         ("e^-x", lambda x: math.exp(-x)), ("tanh", math.tanh)]


def channels():
    ch = {"-": (None, 0)}
    for n, f in PRIMS:
        ch[n] = (f, 1)
    for n1, f1 in PRIMS:
        for n2, f2 in PRIMS:
            ch[f"{n1}[{n2}]"] = ((lambda f1=f1, f2=f2: lambda x: f1(f2(x)))(), 2)
    return ch


def make(af, cf, sk, comb):
    def score(c):
        t = []
        if af:
            t.append(af(c.age if c.age is not None else 0))
        if cf:
            t.append(cf(c.count if c.count is not None else 1))
        if sk:
            t.append(3.0 if c.spk == 2 else 1.0)
        if comb == "mul":
            v = 1.0
            for x in t:
                v *= x
            return v
        return sum(t)
    return score


def run_search(prep, instances):
    memo, live = {}, []
    for inst, (p0, p1, p2, qrel, crel, is_chain) in zip(instances, prep["label_ops_adaptive"]):
        stores = [get_store(memo, "dict", "append", p) for p in (p0, p1, p2)]
        try:
            for st in stores:
                harvest(st, inst["q"][0], qrel, crel, is_chain, WALK, None)
        except NeedScore:
            live.append((inst, stores, qrel, crel, is_chain))

    def ok(sc):
        for inst, stores, qrel, crel, is_chain in live:
            want = (inst["before"], inst["after"], inst["after"])
            if tuple(harvest(st, inst["q"][0], qrel, crel, is_chain, WALK, sc) for st in stores) != want:
                return False
        return True

    ch = channels()
    total, passed, kinds, cheap = 0, 0, {}, []
    for an, (af, ac) in ch.items():
        for cn, (cf, cc) in ch.items():
            for sk in (False, True):
                for comb in ("mul", "add"):
                    active = (af is not None) + (cf is not None) + sk
                    if active == 0 or (active == 1 and comb == "add"):
                        continue
                    total += 1
                    if ok(make(af, cf, sk, comb)):
                        passed += 1
                        kind = "+".join(k for k, on in (("age", af), ("count", cf), ("speaker", sk)) if on)
                        kinds[kind] = kinds.get(kind, 0) + 1
                        cheap.append((ac + cc + sk + (comb == "add"), f"age:{an} count:{cn} speaker:{'auth' if sk else '-'} {comb}"))
    cheap.sort()
    lines = [f"[search] stage 2: {total} self-generated score expressions on {len(live)} score-deciding instances "
             f"(dict + adaptive + append + {'depth%d' % WALK[0]}|typed|inherit): {passed} pass ({100.0 * passed / total:.1f}%)",
             "  passing by channels used: " + ", ".join(f"{k} {v}" for k, v in sorted(kinds.items(), key=lambda kv: -kv[1])),
             "  channel sets that never pass: " + (", ".join(k for k in ("age", "count", "speaker", "age+count", "age+speaker",
                                                         "count+speaker", "age+count+speaker") if k not in kinds) or "none"),
             "  cheapest passing expressions:"]
    lines += [f"    cost {c}: {n}" for c, n in cheap[:8]]
    return lines, {"total": total, "passed": passed, "live_instances": len(live)}
