#!/usr/bin/env python3
"""
PROVISIONAL V2 - WALK (harvest) and SCORE slot fillers.

SCORE is where math transformations sit, as in V1, but now there is something to discriminate:
a candidate carries age (assertions since it was last stated), count and speaker rank, and the
correction scenarios put two candidates at one address. A SCORE filler is a product of up to three
transformed features:
  R  decay of age      none | phi^-age | 1/Fib(age+2) | 2^-age | 1/(1+age) | SRG interference (cos(pi*age/8)+1)/2
  C  growth of count   none | x | log1p(x) | sqrt(x) | x^2
  S  speaker authority none | 3 if the user said it, else 1
Ties between different objects are not broken (V1 broke them by order); a tie is an ambiguous answer
and fails, so a pass can never come from list order.

WALK = (depth, typed, inherit): how many facts may be followed, whether the relation of an edge must
match the question's, and whether a property question climbs the IS_A chain (nearest ancestor wins).
"""

import math

from v2_math import PHI

AMBIG = "<ambiguous>"


class NeedScore(Exception):
    pass


def _fib(n):
    a, b = 1, 1
    for _ in range(n - 1):
        a, b = b, a + b
    return a


DECAYS = {"none": None, "phi": lambda a: PHI ** -a, "fib": lambda a: 1.0 / _fib(a + 2),
          "half": lambda a: 0.5 ** a, "recip": lambda a: 1.0 / (1 + a),
          "cos": lambda a: (math.cos(math.pi * min(a, 8) / 8) + 1) / 2}
GROWTHS = {"none": None, "id": lambda c: c, "log1p": math.log1p, "sqrt": math.sqrt, "square": lambda c: c * c}
SPEAKERS = {"none": None, "auth": lambda r: 3.0 if r == 2 else 1.0}


def make_score(dk, gk, sk):
    d, g, s = DECAYS[dk], GROWTHS[gk], SPEAKERS[sk]

    def score(c):
        v = 1.0
        if d:
            v *= d(c.age if c.age is not None else 0)
        if g:
            v *= g(c.count if c.count is not None else 1)
        if s:
            v *= s(c.spk if c.spk is not None else 0)
        return v
    return score


SCORES = [(f"R:{dk}|C:{gk}|S:{sk}", make_score(dk, gk, sk))
          for dk in DECAYS for gk in GROWTHS for sk in SPEAKERS]  # includes the flat score (no feature)
WALKS = [(d, t, i) for t in (True, False) for i in (True, False) for d in (1, 2, 3, 4, 5, 8)]


def walk_name(w):
    return f"depth{w[0]}|{'typed' if w[1] else 'untyped'}|{'inherit' if w[2] else 'direct'}"


def pick(cands, score):
    if not cands:
        return None
    if len(cands) == 1:
        return cands[0].obj
    if score is None:
        raise NeedScore
    vals = [score(c) for c in cands]
    top = max(vals)
    win = [c.obj for c, v in zip(cands, vals) if v >= top - 1e-9 * max(1.0, abs(top))]
    return win[0] if len(win) == 1 else AMBIG


def harvest(store, subj, qrel, chain_rel, is_chain, walk, score):
    """is_chain: the question asks for the end of the IS_A chain; otherwise for a property qrel."""
    depth, typed, inherit = walk
    if qrel is None or chain_rel is None:
        return None
    cur, seen, last, steps = subj, {subj}, None, 0
    while steps < depth:
        if is_chain:
            p = pick(store.cands(cur, chain_rel if typed else None), score)
            if p is None:
                break
            if p == AMBIG:
                return AMBIG
            steps += 1
            last = p
            if p in seen:
                break
            seen.add(p)
            cur = p
        else:
            here = store.cands(cur, qrel if typed else None)
            if here:
                return pick(here, score)
            if not inherit:
                return None
            p = pick(store.cands(cur, chain_rel if typed else None), score)
            if p is None or p == AMBIG or p in seen:
                return None if p is None or p in seen else AMBIG
            steps += 1
            seen.add(p)
            cur = p
    return last if is_chain else None
