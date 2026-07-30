#!/bin/bash
# Rebuilds ClamshellViewer/FreeRDPKit/CFreeRDP.xcframework from source.
#
# You only need this if you're changing the FreeRDP/OpenSSL version pinned
# below, or adding an architecture slice — the xcframework it produces is
# checked into the repo (~30MB static lib) so a normal `git clone` + open in
# Xcode just works without anyone re-running this. Takes ~10-15 min on an
# Apple Silicon Mac; needs Xcode (iOS + iOS Simulator SDKs) and Homebrew.
#
# What this builds and why:
#  - OpenSSL, cross-compiled twice (device arm64, simulator arm64) via its
#    own Configure ios64-cross / iossimulator-arm64-xcrun targets. FreeRDP
#    requires a crypto backend and there's no iOS-prebuilt OpenSSL to point
#    it at, so this is the one truly manual cross-compile step.
#  - libfreerdp + libwinpr + libfreerdp-client, cross-compiled via FreeRDP's
#    own CMake + the well-maintained leetal/ios-cmake toolchain it vendors
#    (cmake/ios.toolchain.cmake) — NOT the stale client/iOS reference app,
#    which predates arm64 and is not part of this build.
#  - Everything merged per-slice into one static lib with `libtool -static`
#    (an XCFramework binary target wants exactly one library per platform
#    variant) and packaged with `xcodebuild -create-xcframework`.
#
# Known gotcha worth documenting: FreeRDP's CMake enables
# CMAKE_INTERPROCEDURAL_OPTIMIZATION (thin LTO) by default when the compiler
# supports it, which makes clang emit LLVM-bitcode-wrapper .o files instead
# of plain Mach-O. `lipo`/`nm`/`otool` all read those fine (they unwrap to
# the embedded native slice) but `xcodebuild -create-xcframework` rejects them
# outright ("unable to find any architecture information ... Unknown header:
# 0xb17c0de"). Fix is `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF` — nothing to
# do with the deprecated iOS "Enable Bitcode" App Store setting (ENABLE_BITCODE
# is already off below), a completely different LTO knob with a confusingly
# similar failure signature.
#
# Coverage: iOS device arm64 + iOS Simulator arm64 only (matches this repo's
# only Apple Silicon dev/test path). Intel Simulator (x86_64) is not built —
# add a SIMULATOR64 slice below and lipo it into ios-sim-libs if you need it.
set -euo pipefail

FREERDP_VERSION="${FREERDP_VERSION:-3.16.0}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.4.1}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_XCFRAMEWORK="$REPO_ROOT/ClamshellViewer/FreeRDPKit/CFreeRDP.xcframework"
WORK="${FREERDP_BUILD_DIR:-$REPO_ROOT/.build/freerdp-ios}"

command -v cmake >/dev/null || { echo "brew install cmake ninja pkg-config" >&2; exit 1; }
command -v ninja >/dev/null || { echo "brew install cmake ninja pkg-config" >&2; exit 1; }

mkdir -p "$WORK"
cd "$WORK"

# ---- 1. FreeRDP source ----
if [ ! -d freerdp-src ]; then
  git clone --depth 1 --branch "$FREERDP_VERSION" https://github.com/FreeRDP/FreeRDP.git freerdp-src
fi

# ---- 2. OpenSSL, cross-compiled per slice ----
if [ ! -f "openssl-$OPENSSL_VERSION.tar.gz" ]; then
  curl -sL "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" -o "openssl-$OPENSSL_VERSION.tar.gz"
fi

build_openssl() {
  local slice="$1" target="$2" cross_top="$3" cross_sdk="$4"
  local prefix="$WORK/openssl-$slice"
  [ -f "$prefix/lib/libssl.a" ] && return 0
  rm -rf "openssl-build-$slice"
  mkdir -p "openssl-build-$slice"
  tar xzf "openssl-$OPENSSL_VERSION.tar.gz" -C "openssl-build-$slice" --strip-components=1
  (
    cd "openssl-build-$slice"
    CROSS_TOP="$cross_top" CROSS_SDK="$cross_sdk" ./Configure "$target" no-shared no-tests no-asm --prefix="$prefix"
    CROSS_TOP="$cross_top" CROSS_SDK="$cross_sdk" make -j"$(sysctl -n hw.ncpu)" build_libs
    CROSS_TOP="$cross_top" CROSS_SDK="$cross_sdk" make -j"$(sysctl -n hw.ncpu)" install_dev
  )
}

XCODE_DEV="$(xcode-select -p)"
build_openssl device  ios64-cross              "$XCODE_DEV/Platforms/iPhoneOS.platform/Developer"        iPhoneOS.sdk
build_openssl sim     iossimulator-arm64-xcrun  "$XCODE_DEV/Platforms/iPhoneSimulator.platform/Developer" iPhoneSimulator.sdk

# ---- 3. FreeRDP (libfreerdp + libwinpr + libfreerdp-client), per slice ----
build_freerdp() {
  local slice="$1" platform="$2"
  local build="$WORK/freerdp-src/build-ios-$slice"
  local ssl="$WORK/openssl-$slice"
  [ -f "$build/libfreerdp/libfreerdp3.a" ] && return 0
  mkdir -p "$build"
  cmake -S "$WORK/freerdp-src" -B "$build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$WORK/freerdp-src/cmake/ios.toolchain.cmake" \
    -DPLATFORM="$platform" \
    -DDEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DENABLE_BITCODE=OFF -DENABLE_ARC=ON -DENABLE_VISIBILITY=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    -DWITH_CLIENT=OFF -DWITH_SERVER=OFF -DWITH_SHADOW=OFF \
    -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_SDL2=OFF -DWITH_CLIENT_SDL3=OFF \
    -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_PULSE=OFF \
    -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF -DWITH_SWSCALE=OFF \
    -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_KRB5=OFF -DWITH_MANPAGES=OFF \
    -DWITH_CAIRO=OFF -DWITH_OPUS=OFF \
    -DWITH_SIMD=ON \
    -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF \
    -DFREERDP_IOS_EXTERNAL_SSL_PATH="$ssl" \
    -DOPENSSL_ROOT_DIR="$ssl" \
    -DOPENSSL_INCLUDE_DIR="$ssl/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$ssl/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$ssl/lib/libssl.a"
  cmake --build "$build"
}

build_freerdp device OS64
build_freerdp sim    SIMULATORARM64

# ---- 4. Merge each slice's static libs into one, then package as an XCFramework ----
merge_slice() {
  local slice="$1"
  local build="$WORK/freerdp-src/build-ios-$slice"
  local ssl="$WORK/openssl-$slice"
  local outdir="$WORK/xcframework-out/$slice"
  mkdir -p "$outdir"
  libtool -static -o "$outdir/libCFreeRDP.a" \
    "$build/libfreerdp/libfreerdp3.a" \
    "$build/winpr/libwinpr/libwinpr3.a" \
    "$build/client/common/libfreerdp-client3.a" \
    "$build/channels/rdpsnd/common/librdpsnd-common.a" \
    "$build/channels/remdesk/common/libremdesk-common.a" \
    "$ssl/lib/libssl.a" \
    "$ssl/lib/libcrypto.a"
}
merge_slice device
merge_slice sim

HEADERS="$WORK/xcframework-out/headers/freerdp3"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp -R "$WORK/freerdp-src/include/freerdp" "$HEADERS/freerdp"
cp -R "$WORK/freerdp-src/winpr/include/winpr" "$HEADERS/winpr"
# Overlay build-generated headers (version.h, config.h, settings_keys.h — the
# real per-slice content is identical, device vs. sim only differ in already-
# excluded platform macros).
cp -R "$WORK/freerdp-src/build-ios-device/include/freerdp/." "$HEADERS/freerdp/"
cp -R "$WORK/freerdp-src/build-ios-device/winpr/include/winpr/." "$HEADERS/winpr/"

rm -rf "$OUT_XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$WORK/xcframework-out/device/libCFreeRDP.a" -headers "$WORK/xcframework-out/headers" \
  -library "$WORK/xcframework-out/sim/libCFreeRDP.a"    -headers "$WORK/xcframework-out/headers" \
  -output "$OUT_XCFRAMEWORK"

echo "Wrote $OUT_XCFRAMEWORK"
