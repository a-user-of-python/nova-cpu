# Harness fixtures — vendored test inputs

The golden programs that live in the sibling `nova-programs/` tree are NOT
part of the nova-cpu repository, so CI could never check them out. They are
vendored here, verbatim, as test fixtures (test inputs are pinned by nature —
that is the point of a golden baseline).

| Fixture | Source (copied 2026-11-04) |
|---|---|
| `hi.nova` | `~/workspace/nova-programs/hi/hi.nova` |
| `bouncer.nova` | `~/workspace/nova-programs/bouncer/bouncer.nova` |
| `counter.nova` | `~/workspace/nova-programs/counter/counter.nova` |
| `galaxy_fixed.nova` | `~/workspace/nova-programs/galaxy/galaxy_fixed.nova` |
| `galaxy.bin` | `~/workspace/nova-programs/galaxy/galaxy.bin` (generator output of `gen_galaxy.py`; the sibling `galaxy.nova` is a placeholder template and cannot be assembled into a runnable program — see `../README.md`) |

Refresh procedure (only when a golden bump is intended):

```bash
cp ~/workspace/nova-programs/hi/hi.nova               fixtures/hi.nova
cp ~/workspace/nova-programs/bouncer/bouncer.nova     fixtures/bouncer.nova
cp ~/workspace/nova-programs/counter/counter.nova     fixtures/counter.nova
cp ~/workspace/nova-programs/galaxy/galaxy_fixed.nova fixtures/galaxy_fixed.nova
cp ~/workspace/nova-programs/galaxy/galaxy.bin        fixtures/galaxy.bin
# then regenerate goldens:  ../run.sh baseline   (and commit the new goldens)
```
