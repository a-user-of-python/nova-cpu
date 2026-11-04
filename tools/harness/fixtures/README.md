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
| `examples_galaxy.bin` | `~/workspace/nova-cpu/examples/galaxy.bin` (nova-cpu `examples/`; the generator-produced canonical binary for the placeholder-template `examples/galaxy.nova`; sha256 `a1f8f91c8a3152586cd3523e0bef0bd59b8ff87e8658eb834e20ce9e0e4e11c6`, 1,480 B; vendored 2026-11-04 because `examples/galaxy.bin` is not part of the pushed tree, so CI could never check it out) |

Refresh procedure (only when a golden bump is intended):

```bash
cp ~/workspace/nova-programs/hi/hi.nova               fixtures/hi.nova
cp ~/workspace/nova-programs/bouncer/bouncer.nova     fixtures/bouncer.nova
cp ~/workspace/nova-programs/counter/counter.nova     fixtures/counter.nova
cp ~/workspace/nova-programs/galaxy/galaxy_fixed.nova fixtures/galaxy_fixed.nova
cp ~/workspace/nova-programs/galaxy/galaxy.bin        fixtures/galaxy.bin
cp ~/workspace/nova-cpu/examples/galaxy.bin           fixtures/examples_galaxy.bin
# then regenerate goldens:  ../run.sh baseline   (and commit the new goldens)
```
