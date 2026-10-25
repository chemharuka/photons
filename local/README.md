# `local/` — the session workspace (gitignored)

Everything a Hermes session produces while working on Photons lands here, and **none of it is
published**. `.gitignore` ignores `local/*` but keeps this file, which is the convention.

The split exists because the repository is public and MIT, while these are working artifacts:
half-finished notes, machine-specific measurements, third-party source clones we are only reading
for ideas, and photos that belong to the user.

| Path | What goes there | Published? |
|---|---|---|
| `local/research/*.md` | Agent-written source-code studies, measurements, comparisons | ✗ no |
| `local/probes/` | Throwaway probes: one-off Swift/Python that answers a single question | ✗ no |
| `local/tests-scratch/` | Ad-hoc tests that are not (yet) part of the suite in `Tests/` | ✗ no |
| `local/samples/` | RAW/JPEG fixtures, usually symlinks to the user's own photos | ✗ no |
| `local/src/` | Shallow clones of third-party projects read for reference (GPL/AGPL ones stay read-only) | ✗ no |
| `local/out/` | Probe output: rendered JPEGs, logs, measurement dumps | ✗ no |

## Rules

1. **Anything that must survive a `git clone` goes in `docs/` or `Sources/`.** `local/` is disposable
   by definition; a fresh clone will not have it.
2. **A probe that is still needed after the question is answered becomes a test in `Tests/`** — with
   the measurement asserted, not printed. Otherwise delete it.
3. **A research report that changes a decision must be summarised into
   `docs/architecture-decisions.md`** with the evidence and the file/report it came from. The report
   itself stays in `local/research/` and is never cited as if it were a public source.
4. **Never copy GPL/AGPL source here and then paste it into `Sources/`.** Reading for concepts is
   fine; `local/src/` is a reading room, not an import path. Only MIT/Apache/BSD code may be ported,
   and then the original notice travels with it.
5. **Fixtures are referenced, not moved.** `local/samples/x.dng -> ~/Pictures/x.dng` keeps the repo
   small; `PHOTONS_TEST_RAW` points the test suite at it.
6. **Sizes.** `local/src/` can reach gigabytes. `du -sh local/` before complaining that the disk is
   full; delete clones freely, they are re-clonable in seconds.

## Naming

- reports: `local/research/<topic>.md` — one topic per file, headline numbers in the first 10 lines
- probes: `local/probes/<question>.swift` / `.py` — name them after the question they answer
- measurements: `local/out/<topic>-<date>.txt` — raw dumps, paste-free
