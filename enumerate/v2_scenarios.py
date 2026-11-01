#!/usr/bin/env python3
"""
PROVISIONAL V2 - teaching scenarios. Made-up words only, so no prior knowledge can answer.
Every instance is: a tape (background + scenario facts, speaker "corpus"), one teaching input
(speaker "user"), one unrelated teaching input (negative control), and one question.
Pass = before-answer correct AND after-answer correct AND control-answer still the after-answer.

Families (each is built for 3 different generated vocabularies, so no filler passes by luck of
one set of words, and the geometric hashes meet different collisions):
  chain          old chain + new link: answer needs old and new together (V1 scenario A/B shape),
                 with a different-relation edge at a middle node (untyped walking breaks)
  chain_long     same, 4 old links + 1 new link (needs depth 5)
  inherit_has    new property on a middle node; question is a property of the leaf (before: nothing)
  inherit_can    new property two nodes up, different relation; distractor property on the middle
  correct_counted teacher corrects student: old parent stated twice by corpus, new parent once by user
  correct_equal   same, old stated once (count tie; only recency or speaker can decide)
  surface        articles, adjectives, capitals, trailing period (breaks first/last token labelling)
  novel_relation the teaching input brings a relation word never seen on the tape ("a <verb> c")
  legacy_A/B     V1's exact sentences, no background tape (continuity with V1)
"""

from v2_math import SplitMix64

CONS = "bdfgklmnprstvzchjw"
VOW = "aeiou"
FORBID = {"is", "has", "have", "causes", "can", "a", "an", "the"}

FAMILIES = ["chain", "chain_long", "inherit_has", "inherit_can",
            "correct_counted", "correct_equal", "surface", "novel_relation"]
VOCABS = 5


def gen_words(rng, n, taken):
    out = []
    while len(out) < n:
        w = ""
        for _ in range(1 + rng.below(3)):
            w += CONS[rng.below(len(CONS))] + VOW[rng.below(5)]
            if rng.below(2):
                w += CONS[rng.below(len(CONS))]
        if rng.below(5) == 0:
            w += "-" + CONS[rng.below(len(CONS))] + VOW[rng.below(5)] + CONS[rng.below(len(CONS))]
        if len(w) < 3 or w in taken or w in FORBID:
            continue
        taken.add(w)
        out.append(w)
    return out


def _background(w):
    s = [f"{w[0]} is a {w[1]}", f"{w[2]} is a {w[3]}", f"{w[1]} is a {w[4]}",
         f"{w[5]} has a {w[6]}", f"{w[7]} has a {w[8]}", f"{w[4]} has a {w[9]}",
         f"{w[10]} can {w[11]}", f"{w[12]} can {w[13]}", f"{w[6]} can {w[14]}",
         f"{w[15]} causes {w[16]}", f"{w[17]} causes {w[18]}", f"{w[19]} causes {w[20]}"]
    return [(x, "corpus") for x in s]


def _inst(name, family, known, new, subj, op, before, after, ctrl):
    return {"name": name, "family": family, "known": known,
            "new": [(x, "user") for x in new], "control": [(ctrl, "user")],
            "q": (subj, op), "before": before, "after": after}


def vocab_instances(v):
    rng = SplitMix64(0xC0FFEE + v)
    taken = set()
    bg = _background(gen_words(rng, 21, taken))
    out = []
    for fam in FAMILIES:
        a, b, c, d, e, f = gen_words(rng, 6, taken)
        x, y, verb = gen_words(rng, 3, taken)
        ctrl = f"{x} is a {y}"
        k = lambda *ss: bg + [(s, "corpus") for s in ss]
        n = f"{fam}#v{v}"
        if fam == "chain":
            out.append(_inst(n, fam, k(f"{a} is a {b}", f"{b} is a {c}", f"{b} has a {d}"),
                             [f"{c} is a {e}"], a, "is", c, e, ctrl))
        elif fam == "chain_long":
            out.append(_inst(n, fam, k(f"{a} is a {b}", f"{b} is a {c}", f"{c} is a {d}", f"{d} is a {e}"),
                             [f"{e} is a {f}"], a, "is", e, f, ctrl))
        elif fam == "inherit_has":
            out.append(_inst(n, fam, k(f"{a} is a {b}", f"{b} is a {c}", f"{b} can {d}"),
                             [f"{b} has a {e}"], a, "has", None, e, ctrl))
        elif fam == "inherit_can":
            out.append(_inst(n, fam, k(f"{a} is a {b}", f"{b} is a {c}", f"{b} has a {d}"),
                             [f"{c} can {e}"], a, "can", None, e, ctrl))
        elif fam == "correct_counted":
            out.append(_inst(n, fam, k(f"{a} is a {b}", f"{a} is a {b}", f"{b} is a {c}"),
                             [f"{a} is a {d}"], a, "is", c, d, ctrl))
        elif fam == "correct_equal":
            out.append(_inst(n, fam, k(f"{a} is a {b}", f"{b} is a {c}"),
                             [f"{a} is a {d}"], a, "is", c, d, ctrl))
        elif fam == "novel_relation":
            out.append(_inst(n, fam, k(f"{a} is a {b}"), [f"{a} {verb} {c}"], a, verb, None, c, ctrl))
        elif fam == "surface":
            out.append(_inst(n, fam, k(f"The little {a.capitalize()} is a {b}.", f"A {b} is a big {c}."),
                             [f"The {c} is a very tall {e}."], a, "is", c, e, ctrl))
    return out


def legacy_instances():
    """V1's scenarios A and B, sentence for sentence, with V1's unrelated teaching."""
    mk = lambda name, known, new, subj, before, after: {
        "name": name, "family": name, "known": [(s, "corpus") for s in known],
        "new": [(new, "user")], "control": [("zib is a fruit", "user")],
        "q": (subj, "is"), "before": before, "after": after}
    return [mk("legacy_A", ["tib is a glorp", "glorp is a water-dweller"],
               "water-dweller is a river-tib", "tib", "water-dweller", "river-tib"),
            mk("legacy_B", ["kex is a tool", "tool is a worker-item"],
               "worker-item is a wood-cutter", "kex", "worker-item", "wood-cutter")]


def all_instances():
    out = legacy_instances()
    for v in range(VOCABS):
        out += vocab_instances(v)
    return out
