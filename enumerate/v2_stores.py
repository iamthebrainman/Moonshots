#!/usr/bin/env python3
"""
PROVISIONAL V2 - ADDRESS / representation slot fillers ("stores"), one per way of writing the same
facts in different math, each taking the three update policies the teacher/student scenario needs:

  append     keep every assertion (several candidates may share an address)
  overwrite  a new object for the same (subject, relation) replaces the old one (teacher corrects student)
  glue       accept only if consistent with what is held (SUNZI W4: a conflict is refused)

  dict          symbolic table keyed by subject (V1's address_by_subject)
  sunzi_sr      the base is two integers (M, K); key = prime for (subject, relation), value = object id
  sunzi_pair    knowledge.zig layout: key = prime of (subject, object) in the speaker's residue class
                mod 8, value packs relation + confidence; "all facts about X" needs the host's pair list
  word<m>_<h>   THE WORD: the subject's geometric hash h (method m, 16-bit address) selects the slot;
                lookup trusts the address (no subject check), so collisions cross-talk
  map, map_decay  one bundle vector (sum of bound hypervectors), read by unbinding + cosine cleanup;
                map_decay forgets by multiplying the bundle by 0.9 per assertion

candidates(s, r) -> [Cand(obj, age, count, spk)] aggregated per object; r=None reads every relation.
age = assertions since last stated (None where the representation cannot tell), spk = speaker rank.
"""

import functools
from collections import namedtuple
from operator import mul

from v2_math import (Sunzi, Conflict, KEYSPACE, hash_word, HASH_NAMES, vsa_vec, vsa_role, D)

Cand = namedtuple("Cand", "obj age count spk")
RANK = {"user": 2, "corpus": 1}
PRIMES = KEYSPACE[1] + KEYSPACE[3] + KEYSPACE[5] + KEYSPACE[7]
SPEAKER_CLASS = {"user": 1, "corpus": 5}
POLICIES = ["append", "overwrite", "glue"]
_slot = functools.lru_cache(maxsize=None)(hash_word)


def agg(rows, clock):
    best = {}
    for o, last, cnt, spk in rows:
        b = best.get(o)
        if b is None:
            best[o] = [last, cnt, spk]
        else:
            b[0], b[1], b[2] = max(b[0], last), b[1] + cnt, max(b[2], spk)
    return [Cand(o, clock - v[0], v[1], v[2]) for o, v in sorted(best.items())]


class Base:
    def cands(self, s, r):  # cached read; stores are never mutated after they are memoised
        c = self._cc.get((s, r))
        if c is None:
            c = self._cc[(s, r)] = self.candidates(s, r)
        return c


class Entry:
    __slots__ = ("s", "r", "o", "n", "last", "spk")

    def __init__(self, s, r, o, n, last, spk):
        self.s, self.r, self.o, self.n, self.last, self.spk = s, r, o, n, last, spk


class TableStore(Base):
    def __init__(self, policy, method=None):
        self.policy, self.method, self.clock, self.tab, self._cc = policy, method, 0, {}, {}

    def addr(self, s):
        return s if self.method is None else _slot(s, self.method)

    def add(self, f):
        self.clock += 1
        row = self.tab.setdefault(self.addr(f.s), [])
        same = [e for e in row if e.s == f.s and e.r == f.r]  # the host's update logic sees whole facts
        dup = [e for e in same if e.o == f.o]
        if same and not dup:
            if self.policy == "glue":
                return False
            if self.policy == "overwrite":
                row[:] = [e for e in row if e not in same]
        if dup:
            dup[0].n += 1
            dup[0].last, dup[0].spk = self.clock, RANK[f.speaker]
        else:
            row.append(Entry(f.s, f.r, f.o, 1, self.clock, RANK[f.speaker]))
        return True

    def candidates(self, s, r):  # trusts the address: no check that e.s == s
        rows = [(e.o, e.last, e.n, e.spk) for e in self.tab.get(self.addr(s), ()) if r is None or e.r == r]
        return agg(rows, self.clock)

    def copy(self):
        n = TableStore(self.policy, self.method)
        n.clock = self.clock
        n.tab = {k: [Entry(e.s, e.r, e.o, e.n, e.last, e.spk) for e in row] for k, row in self.tab.items()}
        return n


class SunziSR(Base):
    def __init__(self, policy):
        self.policy, self.clock, self._cc = policy, 0, {}
        self.base, self.sr, self.oid, self.names, self.meta = Sunzi(), {}, {}, [], {}

    def add(self, f):
        self.clock += 1
        key = PRIMES[self.sr.setdefault((f.s, f.r), len(self.sr))]
        if f.o not in self.oid:
            self.oid[f.o] = len(self.names)
            self.names.append(f.o)
        oid, cur = self.oid[f.o], self.base.get(key)
        if self.policy == "glue":
            one = Sunzi()
            one.put(key, oid)
            try:
                self.base = self.base.glue(one)
            except Conflict:
                return False
        else:
            self.base.put(key, oid)
        m = self.meta.get(key)
        self.meta[key] = [m[0] + 1 if m and cur == oid else 1, self.clock, RANK[f.speaker]]
        return True

    def candidates(self, s, r):
        rels = [r] if r is not None else [rr for (ss, rr) in self.sr if ss == s]  # untyped read needs the list
        rows = []
        for rr in rels:
            i = self.sr.get((s, rr))
            if i is not None and self.base.has(PRIMES[i]):
                n, last, spk = self.meta[PRIMES[i]]
                rows.append((self.names[self.base.get(PRIMES[i])], last, n, spk))
        return agg(rows, self.clock)

    def copy(self):
        n = SunziSR(self.policy)
        n.clock, n.base = self.clock, Sunzi(self.base.M, self.base.K)
        n.sr, n.oid, n.names = dict(self.sr), dict(self.oid), list(self.names)
        n.meta = {k: list(v) for k, v in self.meta.items()}
        return n


class SunziPair(Base):
    def __init__(self, policy):
        self.policy, self.clock, self._cc = policy, 0, {}
        self.base, self.pair, self.rel, self.meta = Sunzi(), {}, {}, {}

    def _live(self, s):  # the pair list is the index SUNZI itself does not have (GAPS G4)
        out = []
        for (s2, o2), j in self.pair.items():
            if s2 == s:
                for sp, c in SPEAKER_CLASS.items():
                    v = self.base.get(KEYSPACE[c][j])
                    if v is not None:
                        out.append((o2, KEYSPACE[c][j], sp, v & 0x7F, v >> 7))
        return out

    def add(self, f):
        self.clock += 1
        rid = self.rel.setdefault(f.r, len(self.rel))
        j = self.pair.setdefault((f.s, f.o), len(self.pair))
        key = KEYSPACE[SPEAKER_CLASS[f.speaker]][j]
        cur = self.base.get(key)
        conf = min((cur >> 7) + 1, 15) if cur is not None and (cur & 0x7F) == rid else 1
        val = rid | (conf << 7)
        if self.policy == "overwrite":
            for o2, k, sp, r2, c2 in self._live(f.s):
                if r2 == rid and o2 != f.o:
                    self.base.delete(k)
        if self.policy == "glue":
            one = Sunzi()
            one.put(key, val)
            try:
                self.base = self.base.glue(one)  # shares a key only with the same pair + speaker
            except Conflict:
                return False
        else:
            self.base.put(key, val)
        self.meta[key] = self.clock
        return True

    def candidates(self, s, r):
        rid = self.rel.get(r) if r is not None else None
        if r is not None and rid is None:
            return []
        rows = [(o2, self.meta[k], c2, RANK[sp]) for o2, k, sp, r2, c2 in self._live(s) if rid is None or r2 == rid]
        return agg(rows, self.clock)

    def copy(self):
        n = SunziPair(self.policy)
        n.clock, n.base = self.clock, Sunzi(self.base.M, self.base.K)
        n.pair, n.rel, n.meta = dict(self.pair), dict(self.rel), dict(self.meta)
        return n


class MapStore(Base):
    TAU = 0.5

    def __init__(self, policy, gamma=1.0):
        self.policy, self.gamma, self.clock, self._cc = policy, gamma, 0, {}
        self.mem, self.objs, self.rels = [0.0] * D, [], []

    def _bundle(self, s, r, o, w):
        return [w * a * b * c for a, b, c in zip(vsa_role(s), vsa_vec("rel:" + r), vsa_vec(o))]

    def candidates(self, s, r):
        acc = {}
        for rr in ([r] if r is not None else self.rels):
            if rr not in self.rels:
                continue
            x = [m * a * b for m, a, b in zip(self.mem, vsa_role(s), vsa_vec("rel:" + rr))]
            for o in self.objs:
                w = sum(map(mul, x, vsa_vec(o))) / D
                if w >= self.TAU:
                    acc[o] = acc.get(o, 0.0) + w
        return [Cand(o, None, w, None) for o, w in sorted(acc.items())]

    def add(self, f):
        self.clock += 1
        if self.policy != "append":
            diff = [c for c in self.candidates(f.s, f.r) if c.obj != f.o]
            if self.policy == "glue" and diff:
                return False
            for c in diff:  # overwrite: unbind and subtract the old object's bundle
                self.mem = [m + x for m, x in zip(self.mem, self._bundle(f.s, f.r, c.obj, -c.count))]
        if self.gamma != 1.0:
            self.mem = [m * self.gamma for m in self.mem]
        self.mem = [m + x for m, x in zip(self.mem, self._bundle(f.s, f.r, f.o, 1.0))]
        if f.o not in self.objs:
            self.objs.append(f.o)
        if f.r not in self.rels:
            self.rels.append(f.r)
        return True

    def copy(self):
        n = MapStore(self.policy, self.gamma)
        n.clock, n.mem, n.objs, n.rels = self.clock, self.mem[:], self.objs[:], self.rels[:]
        return n


STORE_NAMES = (["dict", "sunzi_sr", "sunzi_pair"]
               + [f"word{m}_{h}" for m, h in enumerate(HASH_NAMES)] + ["map", "map_decay"])


def make_store(name, policy):
    if name == "dict":
        return TableStore(policy)
    if name == "sunzi_sr":
        return SunziSR(policy)
    if name == "sunzi_pair":
        return SunziPair(policy)
    if name.startswith("word"):
        return TableStore(policy, int(name[4]))
    return MapStore(policy, 0.9 if name == "map_decay" else 1.0)


def get_store(memo, name, policy, facts):
    """Replay `facts` (a tuple) incrementally; every prefix is memoised, so teaching a store a new
    fact copies the store that already holds the old ones."""
    key = (name, policy, facts)
    st = memo.get(key)
    if st is None:
        if not facts:
            st = make_store(name, policy)
        else:
            st = get_store(memo, name, policy, facts[:-1]).copy()
            st.add(facts[-1])
        memo[key] = st
    return st
