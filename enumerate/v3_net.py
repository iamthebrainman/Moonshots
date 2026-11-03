#!/usr/bin/env python3
"""
PROVISIONAL V3 - the growing multi-scale whole-word RTN from the architecture sketch, at toy
fidelity, standard library only. Every mechanism is a slot with alternatives, so selection can
tell which ones carry weight.

  scales      0: word->word arcs only | 1: + phrase nodes (stabilised n-grams, entered as macros from
              their first word, expandable back to their words) | 2: + document-level hubs whose
              co-occurrence lift biases the walk (long-range jumps)
  recursion   discovers (opener, closer) pairs from the text (prefix-balanced in every sentence that
              holds them) and recognises with a call/return stack; off = bounded context only
  plasticity  merge: nodes with overlapping continuation sets and no direct adjacency fuse;
              split: a node whose (predecessor, successor) pairs fall into disconnected groups splits
  signal      what decides maintenance: none | count (drop arcs of strength <= 1) | external (chase a
              scalar: drop the weakest 40% of arcs) | intrinsic (tentatively remove an arc, measure the
              change in live states = reachable from <s> and still able to reach </s>, within horizon
              h; keep the arc if the loss exceeds delta; transform count|log)
  staging     phrases need >= 2 documents; merges/splits need more evidence; prune waits for the
              final pass (no destructive move on thin evidence)
Walks are deterministic argmax with name tie-break (no randomness anywhere).
"""

import math
import os
import re

BOUND = ("<s>", "</s>")
TOKEN = re.compile(r"[a-z0-9][a-z0-9'\-]*")


def sentences(text):
    out = []
    for chunk in text.replace("\n", ".").split("."):
        toks = TOKEN.findall(chunk.lower())
        if toks:
            out.append(toks)
    return out


def read_docs(root):
    """A directory tree of plain-text files, walked in sorted order; one document per file."""
    docs = []
    for base, dirs, files in os.walk(root):
        dirs.sort()
        for f in sorted(files):
            if f.endswith(".txt"):
                p = os.path.join(base, f)
                with open(p, encoding="utf-8") as fh:
                    docs.append((os.path.relpath(p, root), sentences(fh.read())))
    return docs


class Cfg:
    def __init__(self, scales=0, recursion=False, plasticity="none", signal=("none",), staging=False):
        self.scales, self.recursion, self.plasticity = scales, recursion, plasticity
        self.signal, self.staging = signal, staging


class Net:
    def __init__(self, cfg):
        self.cfg = cfg
        self.A0, self.A1 = {}, {}  # scale-0 arcs word->word; scale-1 arcs word->phrase macro, phrase->next word
        self.phr, self.defs, self.alias = {}, {}, {}
        self.ng, self.promoted = {}, set()
        self.df, self.co, self.ctx = {}, {}, {}
        self.pairs, self.log = [], []
        self.ndocs = 0

    # ------------------------------------------------------------ streaming update
    def feed(self, sents):
        d, c = self.ndocs, self.cfg
        self.ndocs += 1
        seen = set()
        for toks in sents:
            seq = ["<s>"] + toks + ["</s>"]
            for a in seq:
                self.A0.setdefault(a, {})
            for a, b in zip(seq, seq[1:]):
                row = self.A0[a]
                row[b] = row.get(b, 0.0) + 1.0
            if c.plasticity == "merge+split":
                for p, w, s in zip(seq, seq[1:], seq[2:]):
                    k = self.ctx.setdefault(w, {})
                    k[(p, s)] = k.get((p, s), 0) + 1
            if c.scales >= 1:
                for n in (2, 3, 4):
                    for i in range(len(toks) - n + 1):
                        e = self.ng.setdefault(tuple(toks[i:i + n]), [0, set(), {}])
                        nx = toks[i + n] if i + n < len(toks) else "</s>"
                        e[0] += 1
                        e[1].add(d)
                        e[2][nx] = e[2].get(nx, 0) + 1
            if c.recursion:
                self.log.append(toks)
            seen.update(toks)
        for w in seen:
            self.df.setdefault(w, set()).add(d)
        if c.scales >= 2:
            for w in seen:
                row = self.co.setdefault(w, {})
                for v in seen:
                    if v != w:
                        row[v] = row.get(v, 0) + 1
        if c.scales >= 1:
            self._promote()

    @staticmethod
    def _inside(g, k):
        return len(g) < len(k) and any(k[i:i + len(g)] == g for i in range(len(k) - len(g) + 1))

    def _promote(self):
        need_docs = 2 if self.cfg.staging else 1
        cand = sorted((g for g, e in self.ng.items() if e[0] >= 4 and len(e[1]) >= need_docs and g not in self.promoted),
                      key=lambda g: (-len(g), -self.ng[g][0], g))
        pool = list(self.promoted)
        for g in cand:
            if any(self._inside(g, k) and self.ng[k][0] >= 0.8 * self.ng[g][0] for k in pool):
                continue
            pool.append(g)
            self.promoted.add(g)

    def finalize(self):
        if self.cfg.scales >= 1:
            self.phr, self.A1 = {}, {}
            for g in sorted(self.promoted):
                name = "§" + "_".join(g)
                self.phr[name] = g
                self.A1.setdefault(g[0], {})[name] = float(self.ng[g][0])
                self.A1[name] = {k: float(v) for k, v in self.ng[g][2].items()}
        if self.cfg.recursion:
            self._find_pairs()

    def _find_pairs(self):
        freq = {}
        for toks in self.log:
            for t in toks:
                freq[t] = freq.get(t, 0) + 1
        words = sorted(w for w, n in freq.items() if n >= 5)
        self.pairs = []
        for o in words:
            for cl in words:
                if o == cl:
                    continue
                ok, nsent, deepest = True, 0, 0
                for toks in self.log:
                    if o not in toks and cl not in toks:
                        continue
                    nsent, depth = nsent + 1, 0
                    for t in toks:
                        if t == o:
                            depth += 1
                            deepest = max(deepest, depth)
                        elif t == cl:
                            depth -= 1
                            if depth < 0:
                                ok = False
                                break
                    if not ok or depth != 0:
                        ok = False
                        break
                if ok and nsent >= 5 and deepest >= 2:
                    self.pairs.append((o, cl))

    # ------------------------------------------------------------ scale 2
    def is_hub(self, w):
        return 3 <= len(self.df.get(w, ())) <= 0.65 * self.ndocs

    def lift(self, h, v):
        c = self.co.get(h, {}).get(v, 0)
        if not c:
            return 0.0
        return (c / len(self.df[h])) / (len(self.df[v]) / self.ndocs)

    # ------------------------------------------------------------ maintenance
    def consolidate(self, early=False):
        c = self.cfg
        if not (early and c.staging):
            self._prune()
        if c.plasticity == "merge+split":
            self._split()
        if c.plasticity != "none":
            self._merge()

    def _live(self):
        fwd, stack = {"<s>"}, ["<s>"]
        while stack:
            for v in self.A0.get(stack.pop(), ()):
                if v not in fwd:
                    fwd.add(v)
                    stack.append(v)
        rev = {}
        for u, row in self.A0.items():
            for v in row:
                rev.setdefault(v, []).append(u)
        back, stack = {"</s>"}, ["</s>"]
        while stack:
            for v in rev.get(stack.pop(), ()):
                if v not in back:
                    back.add(v)
                    stack.append(v)
        return fwd & back

    def _fut(self, a, h, live):
        if h == 0:
            return len(live)
        seen, frontier = {a}, [a]
        for _ in range(h):
            nxt = []
            for u in frontier:
                for v in self.A0.get(u, ()):
                    if v not in seen:
                        seen.add(v)
                        nxt.append(v)
            frontier = nxt
        return len(seen & live)

    def _prune(self):
        sig = self.cfg.signal
        if sig[0] == "none":
            return
        arcs = sorted((s, a, b) for a, row in self.A0.items() for b, s in row.items())
        if sig[0] == "count":
            for s, a, b in arcs:
                if s <= 1.0:
                    del self.A0[a][b]
        elif sig[0] == "external":
            for s, a, b in arcs[:int(0.4 * len(arcs))]:
                del self.A0[a][b]
        else:
            _, h, delta, tr = sig
            T = (lambda x: x) if tr == "count" else math.log1p
            live = self._live()
            for s, a, b in arcs:
                if s > 1.0:
                    break
                if b not in self.A0[a]:
                    continue
                before = T(self._fut(a, h, live))
                val = self.A0[a].pop(b)
                live2 = self._live()
                after = T(self._fut(a, h, live2))
                if before > 0 and (before - after) / before > delta + 1e-12:
                    self.A0[a][b] = val
                else:
                    live = live2

    def _merge(self):
        floor = 6 if self.cfg.staging else 2
        words = sorted(w for w, r in self.A0.items() if w not in BOUND and len(r) >= 3 and sum(r.values()) >= floor)
        for i, a in enumerate(words):
            for b in words[i + 1:]:
                if a not in self.A0 or b not in self.A0 or b in self.A0[a] or a in self.A0[b]:
                    continue
                ra, rb = self.A0[a], self.A0[b]
                ta, tb = sum(ra.values()), sum(rb.values())
                keys = sorted(set(ra) | set(rb))
                num = sum(min(ra.get(k, 0) / ta, rb.get(k, 0) / tb) for k in keys)
                den = sum(max(ra.get(k, 0) / ta, rb.get(k, 0) / tb) for k in keys)
                if den and num / den >= 0.6:
                    for k, v in self.A0.pop(b).items():
                        self.A0[a][k] = self.A0[a].get(k, 0.0) + v
                    for row in self.A0.values():
                        if b in row:
                            row[a] = row.get(a, 0.0) + row.pop(b)
                    self.alias[b] = a

    def _split(self):
        floor = 4 if self.cfg.staging else 2
        for w in sorted(self.ctx):
            pairs = self.ctx[w]
            if w not in self.A0 or sum(pairs.values()) < 2 * floor:
                continue
            parent = {}

            def find(x):
                parent.setdefault(x, x)
                while parent[x] != x:
                    parent[x] = parent[parent[x]]
                    x = parent[x]
                return x
            for (p, s) in sorted(pairs):
                parent[find(("p", p))] = find(("s", s))
            comps = {}
            for (p, s), n in sorted(pairs.items()):
                comps.setdefault(find(("p", p)), []).append((p, s, n))
            groups = sorted(comps.values(), key=lambda g: min(p for p, _, _ in g))
            big = [g for g in groups if sum(n for _, _, n in g) >= floor]
            if len(big) < 2:
                continue
            big[0] = big[0] + [x for g in groups if g not in big for x in g]
            dest = {}
            for k, g in enumerate(big, 1):
                name = f"{w}@{k}"
                self.A0[name] = {}
                for p, s, n in g:
                    self.A0[name][s] = self.A0[name].get(s, 0.0) + n
                    dest[p] = name
            for r, row in list(self.A0.items()):  # arcs into w, from the word or from its own split copies
                d = dest.get(r.split("@")[0])
                if d and w in row:
                    row[d] = row.get(d, 0.0) + row.pop(w)
            for row in self.A0.values():
                row.pop(w, None)
            del self.A0[w]

    # ------------------------------------------------------------ interpreter
    def _res(self, w):
        while w in self.alias:
            w = self.alias[w]
        return w

    def successors(self, w):
        return {k.split("@")[0]: v for k, v in self.A0.get(self._res(w), {}).items()}

    def _step(self, cur, ctx, topic):
        base = cur.split("@")[0]
        row = self.A0.get(cur, {})
        if self.cfg.scales >= 1 and ctx is None:
            tot, best = sum(row.values()), None
            for name, s in sorted(self.A1.get(base, {}).items()):
                if name in self.phr and s >= 0.5 * tot and (best is None or s > best[1]):
                    best = (name, s)
            if best:
                parts = self.phr[best[0]]
                return list(parts[1:]), parts[-1], best[0]
        opts = dict(self.A1[ctx]) if ctx is not None and self.A1.get(ctx) else dict(row)
        if not opts:
            return None
        if topic:
            for v in opts:
                opts[v] *= 1.0 + 3.0 * max(0.0, self.lift(topic, v.split("@")[0]) - 1.0)
        v = min(sorted(opts), key=lambda x: -opts[x])
        return [v], v, None

    def gen(self, start, n=12):
        c = self.cfg
        out, ctx = [start], None
        topic = start if c.scales >= 2 and self.is_hub(start) else None
        if c.scales >= 1 and start in self.defs:
            out = list(self.defs[start])
            cur = out[-1]
        else:
            cur = self._res(start)
        while len(out) < n:
            step = self._step(cur, ctx, topic)
            if step is None:
                break
            emit, cur, ctx = step
            if emit[0] == "</s>":
                break
            for w in emit:
                w = w.split("@")[0]
                out.append(w)
                if c.scales >= 2 and self.is_hub(w) and (topic is None or len(self.df[w]) < len(self.df[topic])):
                    topic = w  # the narrowest anchor seen so far holds the topic
        return out

    def accepts(self, toks):
        seq = ["<s>"] + list(toks) + ["</s>"]
        for a, b in zip(seq, seq[1:]):
            if b not in self.A0.get(self._res(a), {}):
                return False
        if self.cfg.recursion and self.pairs:
            closers, opens, stack = {cl: o for o, cl in self.pairs}, {o for o, _ in self.pairs}, []
            for t in toks:
                if t in opens:
                    stack.append(t)
                elif t in closers and (not stack or stack.pop() != closers[t]):
                    return False
            if stack:
                return False
        return True

    # ------------------------------------------------------------ baby mode: a human is one more update source
    def _dead(self):
        return {w for w, r in self.A0.items() if not r and w != "</s>"}

    def confirm(self, a, b):
        self.A0.setdefault(a, {})[b] = self.A0[a].get(b, 0.0) + 3.0
        self.A0.setdefault(b, {})

    def reject(self, a, b):
        before = self._dead()
        row = self.A0.get(a, {})
        if b in row:
            row[b] *= 0.25
            if row[b] < 1.0:
                del row[b]
        if self.cfg.signal[0] != "intr":
            return None  # no meter, nothing to surface
        return {"dead_end": sorted(self._dead() - before)}

    def define(self, word, parts):
        self.A0.setdefault(word, {})
        if self.cfg.scales >= 1:
            self.defs[word] = tuple(parts)
            self.phr["§def:" + word] = tuple(parts)

    def expand(self, unit):
        return self.phr.get(unit, (unit,))

    def digest(self):
        import hashlib
        h = hashlib.sha256()
        for a in sorted(self.A0):
            h.update(f"{a}:{sorted(self.A0[a].items())}\n".encode())
        h.update(repr((sorted(self.phr.items()), sorted(self.alias.items()), self.pairs)).encode())
        return h.hexdigest()[:16]


def train(cfg, docs, early_after=0):
    net = Net(cfg)
    for i, (_, sents) in enumerate(docs):
        net.feed(sents)
        if i + 1 == early_after:
            net.consolidate(early=True)
    net.consolidate()
    net.finalize()
    return net
