#!/usr/bin/env python3
"""
PROVISIONAL V3 - synthetic nested text corpora, written as real files (one directory per probe,
documents as .txt, periods between sentences) so the streaming updater reads a directory tree the
way the sketch describes. Every content word is made up, so only structure can answer a probe.

  a_stage   a burst phrase in the first document only, a coincidence of thin evidence in the first
            document, a genuine phrase in every later document, and later divergence
  b_phrase  a three-word phrase whose middle word has a heavier continuation elsewhere
  c_topic   two topics sharing a five-word function run; the topic decides the word after the run
  d_recur   nested opener/closer sentences, depth 0..2
  e_merge   two words used interchangeably (one has an extra rare continuation), two that are not
  f_split   one word with two senses (disjoint predecessor/successor groups)
  g_prune   a regular base graph, 12 stray bigrams (noise), 8 rare entry arcs into 3-word chains
            reachable no other way (bridges)
  h_baby    a tiny chain for the human-update interface
"""

import os
import shutil

from v2_math import SplitMix64
from v2_scenarios import gen_words


def _write(base, rel, lines):
    p = os.path.join(base, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(" .\n".join(lines) + " .\n")


def build_all(base):
    if os.path.isdir(base):
        shutil.rmtree(base)
    rng, taken = SplitMix64(0x5EED3), set()
    W = lambda n: gen_words(rng, n, taken)
    meta = {}

    spu, rio, ous, ab, cd, gn, uin, ept = W(8)
    s, t, u = W(3), W(4), W(4)
    _write(base, "a_stage/d00.txt", [f"{spu} {rio} {ous}"] * 6 + [f"{ab} {x}" for x in s] + [f"{cd} {x}" for x in s])
    for i in range(1, 8):
        _write(base, f"a_stage/d{i:02d}.txt", [f"{gn} {uin} {ept}"] * 3
               + [f"{ab} {x}" for x in t] * 2 + [f"{cd} {x}" for x in u] * 2)
    meta["stage"] = dict(burst=(spu, rio, ous), genuine=(gn, uin, ept), ab=ab, cd=cd)

    p1, p2, p3, q, sx = W(5)
    xs, ys, zs = W(6), W(6), W(4)
    for d in range(6):
        lines = [f"{xs[(d + k) % 6]} {p1} {p2} {p3} {ys[(d * 2 + k) % 6]}" for k in range(2)]
        lines += [f"{zs[(d + k) % 4]} {p2} {q}" for k in range(3)] + [f"{xs[d % 6]} {p1} {sx}"]
        _write(base, f"b_phrase/d{d:02d}.txt", lines)
    meta["phrase"] = dict(phrase=(p1, p2, p3))

    A0, A1, B0, B1, F = W(6), W(6), W(6), W(6), W(5)  # starters and enders per topic, shared function run
    run = " ".join(F)
    for d in range(8):
        _write(base, f"c_topic/A/d{d:02d}.txt", [f"{A0[(d + k) % 6]} {run} {A1[(5 * d + k + 1) % 6]}" for k in range(6)])
    for d in range(12):
        _write(base, f"c_topic/B/d{d:02d}.txt", [f"{B0[(d + k) % 6]} {run} {B1[(5 * d + k + 1) % 6]}" for k in range(6)])
    meta["topic"] = dict(A=(A0, A1), B=(B0, B1))

    op, cl = W(2)
    lines = []
    for w in W(3):
        lines += [w] * 2 + [f"{op} {w} {cl}"] * 3 + [f"{op} {op} {w} {cl} {cl}"] * 3
    _write(base, "d_recur/d00.txt", lines)
    meta["recur"] = dict(op=op, cl=cl, w=lines[0])

    bik, lam, rizu = W(3)
    ns, qs, rs = W(6), W(4), W(4)
    vex, pon = W(2)
    lines = [f"{bik} {n}" for n in ns] * 4 + [f"{lam} {n}" for n in ns] * 4 + [f"{bik} {rizu}"] * 3
    lines += [f"{vex} {x}" for x in qs] * 4 + [f"{pon} {qs[0]}"] * 4 + [f"{pon} {x}" for x in rs] * 4
    _write(base, "e_merge/d00.txt", lines)
    meta["merge"] = dict(a=bik, b=lam, extra=rizu, c=vex, d=pon)

    river, muddy, cash, loan, bnk, water, reed, teller, vault = W(9)
    lines = [f"{p} {bnk} {x}" for p in (river, muddy) for x in (water, reed)] * 3
    lines += [f"{p} {bnk} {x}" for p in (cash, loan) for x in (teller, vault)] * 4
    _write(base, "f_split/d00.txt", lines)
    meta["split"] = dict(r=river, c=cash, w=bnk, s1=(water, reed), s2=(teller, vault))

    D, J, N, V = W(3), W(4), W(8), W(6)
    base_lines = [f"{D[i % 3]} {J[(i // 3) % 4]} {N[i % 8]} {V[i % 6]} {D[(i + 1) % 3]} {N[(i * 3 + 1) % 8]}"
                  for i in range(120)]
    for d in range(6):
        _write(base, f"g_prune/d{d:02d}.txt", base_lines[d * 20:(d + 1) * 20])
    noise = [(N[i], J[i % 4]) for i in range(8)] + [(N[i], J[(i + 1) % 4]) for i in range(4)]
    chains = [W(3) for _ in range(8)]
    _write(base, "g_prune/d06.txt", [f"{a} {b}" for a, b in noise]
           + [f"{N[i]} {' '.join(chains[i])}" for i in range(8)])
    meta["prune"] = dict(noise=noise, bridges=[w for c in chains for w in c])

    a, b, c, new = W(4)
    _write(base, "h_baby/d00.txt", [f"{a} {b} {c}"] * 3)
    meta["baby"] = dict(chain=(a, b, c), new=new)
    return meta
