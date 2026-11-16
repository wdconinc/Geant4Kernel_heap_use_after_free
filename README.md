# Geant4Kernel heap-use-after-free reproducer

Minimal reproducer for a heap-use-after-free in DD4hep's `Geant4Kernel` phase teardown.
On macOS it shows up as a segfault at exit of `t_LHeD_DDG4_sim_LHeDACLick_as_ACLick_LONGTEST`.

## The bug

`Geant4ActionPhase` is a reference-counted `Geant4Action`: the kernel keeps the initial
reference, and a `Geant4Handle` adds a reference when assigned and releases it when destroyed.
`Geant4Kernel::destroyPhases()` (called from `terminate()`) and `removePhase()`, however, `delete`
the phases, ignoring the reference count. A handle that still holds a phase across `terminate()`
then calls `release()` on freed memory:

```cpp
Phase p;                                          // Geant4Handle<Geant4ActionPhase>
p = kernel.addPhase<const G4Run*>("EndRun");      // refcount 2
kernel.terminate();                               // phase deleted
}                                                 // ~Phase() -> release() on freed memory
```

This is the pattern in `examples/LHeD/scripts/LHeDACLick.C` and
`examples/CLICSiD/scripts/CLICSiDAClick.C`. On Linux the stray write into the freed chunk goes
unnoticed; on macOS the memory is reused and the test crashes.

The fix ([`fix.patch`](fix.patch)) makes the kernel only drop its own reference
(`releaseObjects` / `release()`), as it already does for global actions and filters.

## CI

[`.github/workflows/reproducer.yml`](.github/workflows/reproducer.yml) builds a minimal DD4hep
(DDCore and DDG4 only) with AddressSanitizer on top of an LCG view, as the DD4hep CI does, and
runs [`reproducer`](Geant4Kernel_heap_use_after_free.cpp) against it in two variants:

| variant   | DD4hep                         | expected outcome                                     |
|-----------|--------------------------------|------------------------------------------------------|
| `unfixed` | `AIDASoft/DD4hep` as is        | ASan heap-use-after-free in `Geant4Action::release()` |
| `fixed`   | with `fix.patch` applied       | runs to completion, no ASan report                   |

Each job succeeds only if its expected outcome is observed; the full output is uploaded as an
artifact. A different DD4hep branch, tag or SHA can be tested with "Run workflow".

## Running locally

With an LCG view set up (e.g. inside `ghcr.io/aidasoft/el9` with `/cvmfs` mounted):

```bash
source /cvmfs/sft.cern.ch/lcg/views/LCG_110/x86_64-el9-gcc14-opt/setup.sh
git clone https://github.com/AIDASoft/DD4hep.git
./reproduce.sh DD4hep work uaf                         # unfixed
git -C DD4hep apply ../fix.patch && rm -rf work
./reproduce.sh DD4hep work clean                       # fixed
```
