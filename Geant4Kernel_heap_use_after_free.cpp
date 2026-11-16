// Reproducer for the teardown crash of t_LHeD_DDG4_sim_LHeDACLick_as_ACLick_LONGTEST:
// same handle/phase ownership pattern as setupG4_CINT() in examples/LHeD/scripts/LHeDACLick.C
//
// Build DD4hep with ASan (clang; C++ standard must match Geant4's, here 23):
//   cmake -GNinja <DD4hep src> -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_CXX_STANDARD=23 \
//     -DCMAKE_BUILD_TYPE=Debug -DDD4HEP_USE_GEANT4=ON -DDD4HEP_RELAX_PYVER=ON \
//     -DCMAKE_CXX_FLAGS="-fsanitize=address -fno-omit-frame-pointer" \
//     -DCMAKE_SHARED_LINKER_FLAGS="-fsanitize=address -shared-libsan"
//   ninja
//
// Compile (W = DD4hep source, B = the ASan build directory above):
//   clang++ -std=c++23 -g -fsanitize=address -shared-libsan -fno-omit-frame-pointer \
//     -o phase_uaf phase_uaf.cpp \
//     -I$W/DDCore/include -I$W/DDG4/include -I$W/DDParsers/include -I$B/include \
//     $(root-config --cflags | sed 's/-std=[^ ]*//') $(geant4-config --cflags | sed 's/-std=[^ ]*//') \
//     -L$B/lib -lDDG4 -lDDCore -Wl,-rpath,$B/lib \
//     $(root-config --libs) -lGeom $(geant4-config --libs)
//
// Run (put $B/lib first: LD_LIBRARY_PATH overrides the RUNPATH, and an installed
// uninstrumented DD4hep must not be picked up; also add the clang ASan runtime dir):
//   LD_LIBRARY_PATH=$B/lib:$(dirname $(clang++ -print-file-name=libclang_rt.asan-x86_64.so)):$LD_LIBRARY_PATH \
//     ASAN_OPTIONS=detect_leaks=0 ./phase_uaf
// Without the fix: heap-use-after-free in Geant4Action::release() from ~Geant4Handle.
// With the fix: prints "TEST_PASSED" and "Handle released", no ASan report.

#include <DD4hep/Detector.h>
#include <DDG4/Geant4Kernel.h>
#include <DDG4/Geant4ActionPhase.h>
#include <DDG4/Geant4Handle.h>
#include <G4Run.hh>
#include <iostream>

using namespace dd4hep::sim;
typedef Geant4Handle<Geant4ActionPhase> Phase;   // as in DDG4/Factories.h / Geant4Config.h

int main()  {
  Geant4Kernel& kernel = Geant4Kernel::instance(dd4hep::Detector::getInstance());
  {
    Phase p;
    p = kernel.addPhase<const G4Run*>("BeginRun");
    p = kernel.addPhase<const G4Run*>("EndRun");
    kernel.terminate();
    std::cout << "TEST_PASSED" << std::endl;
  }   // ~Phase() -> Geant4Action::release() on the phase deleted by terminate()
  std::cout << "Handle released" << std::endl;
  return 0;
}

