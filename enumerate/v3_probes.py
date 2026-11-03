#!/usr/bin/env python3
"""
PROVISIONAL V3 - the sketch's claims as mechanical probes. Each probe trains a fresh net from a
directory of text files and checks one claim by reading the graph or walking it; no judge, no
model. A probe runs only the slots it exercises (the rest inert); the integration probe then
trains ONE net on every corpus at once with the full configuration and re-runs every check.

  grow    no frozen vocabulary: starts empty, an unseen word becomes a state on first sight
  phrase  a stabilised phrase is one node: a walk from its first word completes it even though the
          middle word's heaviest continuation is elsewhere; the node expands back to its words
  topic   a hub keeps a walk on topic across a function-word run shared by both topics
  recur   nesting deeper than any training sentence is accepted, unbalanced nesting is refused
  merge   interchangeable words fuse (a continuation seen after one is available after the other);
          words with different continuations do not
  split   a two-sense word splits so each sense keeps its own continuations
  prune   maintenance removes redundant stray arcs (>= 90%) but leaves no dead end and strands no
          state (rare arcs that are the only way into a branch stay)
  stage   a one-document burst never becomes a phrase, a stable phrase does, and thin early
          evidence does not fuse words that later diverge
  baby    a human edit is an ordinary graph update: "this means X" makes a definitional node that a
          walk expands, and rejecting a word's last exit is surfaced as a dead end
"""

import copy
import os

from v3_corpora import build_all
from v3_net import Cfg, Net, read_docs, train


def check_phrase(net, m):
    ph = tuple(m["phrase"]["phrase"])
    out = net.gen(ph[0], 4)
    node = [k for k, g in net.phr.items() if g == ph]
    done = out[:3] == list(ph)
    return done and bool(node) and net.expand(node[0]) == ph, f"completes={done} node={'yes' if node else 'no'}"


def check_topic(net, m):
    (A0, A1), (B0, B1) = m["topic"]["A"], m["topic"]["B"]
    good = 0
    for starts, ends in ((A0, A1), (B0, B1)):
        for seed in (starts[0], starts[2], starts[4]):
            first = next((w for w in net.gen(seed, 20)[1:] if w in A1 or w in B1), None)
            good += first in ends
    return good == 6, f"{good}/6 seeds end on their own topic's word"


def check_recur(net, m):
    op, cl, w = m["recur"]["op"], m["recur"]["cl"], m["recur"]["w"]
    good = [[op] * k + [w] + [cl] * k for k in range(3, 7)]
    bad = [[op] * k + [w] + [cl] * (k - 1) for k in range(3, 7)] + [[op] * (k - 1) + [w] + [cl] * k for k in range(3, 7)]
    a, r = sum(net.accepts(x) for x in good), sum(not net.accepts(x) for x in bad)
    return a == len(good) and r == len(bad), f"accepts {a}/{len(good)} deep valid, refuses {r}/{len(bad)} unbalanced"


def check_merge(net, m):
    mm = m["merge"]
    gen = mm["extra"] in net.successors(mm["b"])
    keep = net._res(mm["c"]) == mm["c"] and net._res(mm["d"]) == mm["d"]
    return gen and keep, f"generalises={gen} distinct words kept apart={keep}"


def check_split(net, m):
    s = m["split"]
    o1, o2 = net.gen(s["r"], 3), net.gen(s["c"], 3)
    ok = len(o1) == 3 and o1[1] == s["w"] and o1[2] in s["s1"] and len(o2) == 3 and o2[2] in s["s2"]
    return ok, f"senses {'separate' if ok else 'mixed'}"


def check_prune(net, m):
    noise, bridges = m["prune"]["noise"], m["prune"]["bridges"]
    removed = sum(1 for a, b in noise if b not in net.A0.get(a, {}))
    live = net._live()
    stranded, dead = sum(1 for w in bridges if w not in live), len(net._dead())
    return removed >= 0.9 * len(noise) and stranded == 0 and dead == 0, \
        f"noise removed {removed}/{len(noise)}, stranded {stranded}, dead ends {dead}"


def check_stage(net, m):
    s, kept = m["stage"], set(net.phr.values())
    a, b = tuple(s["burst"]) not in kept, tuple(s["genuine"]) in kept
    c = net._res(s["ab"]) == s["ab"] and net._res(s["cd"]) == s["cd"]
    return a and b and c, f"burst refused={a} stable phrase kept={b} no early fusion={c}"


def check_baby(net, m):
    a, b, c = m["baby"]["chain"]
    new = m["baby"]["new"]
    net.define(new, [a, b])
    ok1, ok2 = net.gen(new, 4)[:2] == [a, b], net.expand("§def:" + new) == (a, b)
    rep = net.reject(b, c)
    ok3 = rep is not None and b in rep["dead_end"]
    return ok1 and ok2 and ok3, f"definition walks={ok1} expands={ok2} dead end surfaced={ok3}"


def check_grow(cfg):
    net = Net(cfg)
    empty = not net.A0
    net.feed([["xaa", "yaa"]])
    n = len(net.A0)
    net.feed([["zuu"]])
    ok = empty and "xaa" in net.A0 and "yaa" in net.A0 and "zuu" in net.A0 and len(net.A0) == n + 1
    return ok, "starts empty, new words become states" if ok else "vocabulary not open"


# name, slots it exercises, corpus directory, documents before the early checkpoint, check
PROBES = [
    ("grow", (), None, 0, None),
    ("phrase", ("scales", "staging", "plasticity"), "b_phrase", 0, check_phrase),
    ("topic", ("scales", "staging", "plasticity"), "c_topic", 0, check_topic),
    ("recur", ("recursion",), "d_recur", 0, check_recur),
    ("merge", ("plasticity", "staging"), "e_merge", 0, check_merge),
    ("split", ("plasticity", "staging"), "f_split", 0, check_split),
    ("prune", ("signal",), "g_prune", 0, check_prune),
    ("stage", ("scales", "staging", "plasticity"), "a_stage", 1, check_stage),
    ("baby", ("scales", "signal"), "h_baby", 0, check_baby),
]
CHECKS = {p[0]: p[4] for p in PROBES if p[4]}
INERT = dict(scales=0, recursion=False, plasticity="none", signal=("none",), staging=False)


class Env:
    def __init__(self, base):
        self.base, self.meta, self._docs = base, build_all(base), {}

    def docs(self, sub):
        if sub not in self._docs:
            self._docs[sub] = read_docs(os.path.join(self.base, sub) if sub else self.base)
        return self._docs[sub]


def run_probe(env, probe, slots):
    name, deps, sub, early, check = probe
    if name == "grow":
        return check_grow(Cfg(**INERT))
    kw = dict(INERT)
    kw.update({k: slots[k] for k in deps})
    return check(train(Cfg(**kw), env.docs(sub), early), env.meta)


def run_integration(env, slots):
    """One net, every corpus, the full configuration, then every check."""
    net = train(Cfg(**slots), env.docs(""), 1)
    failed = []
    for name in ("phrase", "topic", "recur", "merge", "split", "prune", "stage"):
        if not CHECKS[name](net, env.meta)[0]:
            failed.append(name)
    if not CHECKS["baby"](copy.deepcopy(net), env.meta)[0]:
        failed.append("baby")
    return not failed, ("all checks hold" if not failed else "fails " + ", ".join(failed))
