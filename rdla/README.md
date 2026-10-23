# rdla

Tape + positions index (memory-mapped) with slot-requirement lenses and a Dada-style answer realiser.
Zig 0.16. No dependencies.

    zig test src/main.zig                                   # 13 tests
    zig build-exe src/main.zig -O ReleaseFast -femit-bin=rdla

    rdla index <tape.txt> <idioms.txt|-> <out.rdlt>         # build the mapped tape + index
    rdla ask   <out.rdlt> "What is pizza?"                  # answer, with the tape sentence as evidence
    rdla probe <out.rdlt> pizza                             # show the is-a slot matches for a word
    rdla <tape.txt> [idioms.txt|-] [shards] [window] [out.rdla]   # context-bundle report (operator ranking)

Idiom file lines:  "figure out" means to understand by calculating
Files: src/tok.zig tokens, idiom.zig idioms, lens.zig tape+index+lenses, gen.zig question frames and
templates, ctx.zig/store.zig context bundles. Design notes: ARCH.md.
