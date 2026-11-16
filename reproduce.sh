#!/usr/bin/env bash
# Build a minimal DD4hep (DDCore + DDG4 only) with AddressSanitizer on top of an LCG view,
# compile the reproducer against it, run it and check the outcome.
#
# Usage: reproduce.sh <DD4hep source dir> <work dir> <expect: uaf|clean>
#   uaf   : succeed only if ASan reports the heap-use-after-free in Geant4Action::release()
#   clean : succeed only if the reproducer runs to completion without any ASan report
#
# Expects an LCG view to be set up already (source <view>/setup.sh), which provides
# the compiler, ROOT, Geant4, Boost, Python and CMake.
set -euo pipefail

src=$(realpath "$1")
work=$(realpath -m "$2")
expect=$3
here=$(dirname "$(realpath "$0")")
build=${work}/build
mkdir -p "${work}"

asan_flags="-fsanitize=address -fno-omit-frame-pointer"
# DD4hep must use the same C++ standard as ROOT
std=$(root-config --cflags | grep -o -- '-std=c++[0-9a-z]*' | sed 's/-std=c++//')
cxx=${CXX:-g++}
echo "Compiler: $(${cxx} --version | head -1); C++${std}"
echo "ROOT $(root-config --version), Geant4 $(geant4-config --version)"
echo "DD4hep $(git -C "${src}" log -1 --format='%h %s' 2>/dev/null || echo "(not a git checkout)")"
git -C "${src}" diff --stat 2>/dev/null || true

# Build-time helpers (e.g. listcomponents) load instrumented libraries into
# uninstrumented executables; do not let ASan abort on that
export ASAN_OPTIONS=verify_asan_link_order=0:detect_leaks=0

echo "::group::Configure DD4hep"
cmake -S "${src}" -B "${build}" -GNinja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_STANDARD="${std}" \
  -DCMAKE_CXX_FLAGS="${asan_flags}" \
  -DCMAKE_SHARED_LINKER_FLAGS="-fsanitize=address" \
  -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address" \
  -DDD4HEP_BUILD_PACKAGES="DDG4" \
  -DDD4HEP_USE_GEANT4=ON \
  -DDD4HEP_USE_XERCESC=OFF \
  -DDD4HEP_USE_LCIO=OFF \
  -DDD4HEP_USE_EDM4HEP=OFF \
  -DDD4HEP_USE_HEPMC3=OFF \
  -DDD4HEP_USE_TBB=OFF \
  -DBoost_NO_BOOST_CMAKE=ON \
  -DBUILD_TESTING=OFF
echo "::endgroup::"

echo "::group::Build DDCore and DDG4"
cmake --build "${build}" --target DDG4
echo "::endgroup::"

echo "::group::Build reproducer"
# shellcheck disable=SC2046
${cxx} -g ${asan_flags} -o "${work}/reproducer" "${here}/Geant4Kernel_heap_use_after_free.cpp" \
  -I"${src}/DDCore/include" -I"${src}/DDG4/include" -I"${src}/DDParsers/include" -I"${build}/include" \
  $(root-config --cflags) $(geant4-config --cflags) \
  -L"${build}/lib" -lDDG4 -lDDCore -Wl,-rpath,"${build}/lib" \
  $(root-config --libs) -lGeom $(geant4-config --libs)
echo "::endgroup::"

echo "::group::Run reproducer"
export ASAN_OPTIONS=detect_leaks=0
rc=0
LD_LIBRARY_PATH=${build}/lib:${LD_LIBRARY_PATH:-} "${work}/reproducer" > "${work}/run.log" 2>&1 || rc=$?
cat "${work}/run.log"
echo "::endgroup::"
echo "Reproducer exit code: ${rc}"

uaf=0
grep -q "ERROR: AddressSanitizer: heap-use-after-free" "${work}/run.log" \
  && grep -q "Geant4Action::release" "${work}/run.log" && uaf=1
any_asan=0
grep -q "ERROR: AddressSanitizer" "${work}/run.log" && any_asan=1

case ${expect} in
  uaf)
    if [ ${uaf} -eq 1 ]; then
      echo "OK: heap-use-after-free in Geant4Action::release() reproduced, as expected"
      exit 0
    fi
    echo "UNEXPECTED: the heap-use-after-free was not reproduced"
    exit 1 ;;
  clean)
    if [ ${rc} -eq 0 ] && [ ${any_asan} -eq 0 ] && grep -q "Handle released" "${work}/run.log"; then
      echo "OK: reproducer ran cleanly, as expected"
      exit 0
    fi
    echo "UNEXPECTED: reproducer failed or ASan reported an error"
    exit 1 ;;
  *)
    echo "Unknown expectation '${expect}' (use uaf or clean)"
    exit 2 ;;
esac
