#!/usr/bin/env python3
"""
PROVISIONAL V2 - LABEL slot fillers: raw sentence -> typed triple (subject, relation, object).
V1 labelled (subject, object) pairs. The framework's stores (SUNZI, SRG, RDLA) all carry a
relation, so V2 labels triples. qrel(op) tells the harvester which relation id this labeler
assigns to a question word ("is", "has", "can"), so a query uses the labeler's own vocabulary.

  label_ops_listed   hand-entered operator list (what lens.zig / gen.zig do today)
  label_ops_induced  operator words derived from the tape: document frequency >= theta and never
                     the first or last token of any sentence (ARCH.md: "deriving the operator
                     lists from the tape is the next step")
  label_ops_adaptive induced operators, and a 3-token sentence with no known operator teaches its
                     middle token as a new relation (the new input brings its own relation word)
  label_first_last   V1 filler, now typed as IS_A for everything
  label_reverse      control, swaps subject and object
  label_whole        control, the sentence is both ends
"""

from collections import namedtuple

Fact = namedtuple("Fact", "s r o speaker")

ARTICLES = ("a", "an", "the")
OPS = {"is": "IS_A", "has": "HAS", "have": "HAS", "causes": "CAUSES", "can": "CAN"}


def tokens(sentence):
    out = []
    for w in sentence.split():
        w = w.strip().lower().strip(".,;:!?")
        if w and w not in ARTICLES:
            out.append(w)
    return out


def _split(toks, is_op):
    for i in range(1, len(toks) - 1):
        if is_op(toks[i]):
            return i
    return None


class Listed:
    name = "label_ops_listed"

    def fit(self, tape):
        pass

    def label(self, sentence, speaker):
        t = tokens(sentence)
        i = _split(t, lambda w: w in OPS)
        return None if i is None else Fact(t[i - 1], OPS[t[i]], t[-1], speaker)

    def qrel(self, op):
        return OPS.get(op)


class Induced:
    name = "label_ops_induced"

    def __init__(self, theta=0.15):
        self.theta, self.ops = theta, set()

    def fit(self, tape):
        toks = [tokens(s) for s in tape]
        n = max(len(toks), 1)
        df, edge = {}, set()
        for t in toks:
            for w in set(t):
                df[w] = df.get(w, 0) + 1
            if t:
                edge.add(t[0])
                edge.add(t[-1])
        self.ops = {w for w, c in df.items() if c / n >= self.theta and w not in edge}

    def label(self, sentence, speaker):
        t = tokens(sentence)
        i = _split(t, lambda w: w in self.ops)
        return None if i is None else Fact(t[i - 1], t[i], t[-1], speaker)

    def qrel(self, op):
        return op if op in self.ops else None


class Adaptive(Induced):
    """Induced operators plus one-shot learning: a three-token sentence with no known operator
    teaches its middle token as a new operator (a new relation) on the spot."""
    name = "label_ops_adaptive"

    def label(self, sentence, speaker):
        f = super().label(sentence, speaker)
        if f is not None:
            return f
        t = tokens(sentence)
        if len(t) == 3:
            self.ops.add(t[1])
            return Fact(t[0], t[1], t[2], speaker)
        return None


class FirstLast:
    name = "label_first_last"

    def fit(self, tape):
        pass

    def label(self, sentence, speaker):
        t = tokens(sentence)
        return Fact(t[0], "IS_A", t[-1], speaker) if len(t) >= 2 else None

    def qrel(self, op):
        return "IS_A"


class Reverse:
    name = "label_reverse"

    def fit(self, tape):
        pass

    def label(self, sentence, speaker):
        f = Listed().label(sentence, speaker)
        return None if f is None else Fact(f.o, f.r, f.s, f.speaker)

    def qrel(self, op):
        return OPS.get(op)


class Whole:
    name = "label_whole"

    def fit(self, tape):
        pass

    def label(self, sentence, speaker):
        text = " ".join(tokens(sentence))
        return Fact(text, "IS_A", text, speaker) if text else None

    def qrel(self, op):
        return "IS_A"


LABELERS = [Listed, Induced, Adaptive, FirstLast, Reverse, Whole]
