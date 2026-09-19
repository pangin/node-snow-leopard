#!/bin/bash
# Build Node.js 20.19.5 for Mac OS X 10.6.8 on 32-bit Intel.
#
#   ./build-snow-leopard.sh configure   regenerate the gyp build files
#   ./build-snow-leopard.sh             build (resumable)
#   ./build-snow-leopard.sh status      show progress
#   ./build-snow-leopard.sh install     install into $PREFIX
#   ./build-snow-leopard.sh clean       drop object files, keep configuration
#   ./build-snow-leopard.sh distclean   drop everything generated
#
# Run it from the root of this source tree. See SNOW_LEOPARD.md for the
# toolchain this expects and BACKPORT_MATRIX.md for what each patch addresses.
set -u

MP=${MP:-/opt/local}
PREFIX=${PREFIX:-$HOME/.local/node20}
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 2)}

WORK=$(cd "$(dirname "$0")" && pwd)
SHIM=$WORK/.sl-shim
LOG=$WORK/build-snow-leopard.log
STATUS=$WORK/.sl-status

# MacPorts leaves the plain python3 name to `port select`, which needs root.
# gyp-mac-tool and several V8 scripts start with #!/usr/bin/env python3, so
# provide the name ourselves instead of touching the MacPorts prefix.
mkdir -p "$SHIM"
if [ ! -e "$SHIM/python3" ]; then
  for c in python3.14 python3.13 python3.12 python3.11 python3.10 python3.9; do
    if [ -x "$MP/bin/$c" ]; then ln -sf "$MP/bin/$c" "$SHIM/python3"; break; fi
  done
fi
[ -e "$SHIM/python3" ] || { echo "no MacPorts python3 found under $MP/bin"; exit 1; }
PY=$SHIM/python3

export PATH=$SHIM:$MP/bin:$MP/sbin:/usr/bin:/bin:/usr/sbin:/sbin
export MACOSX_DEPLOYMENT_TARGET=10.6

CC_BIN=$MP/bin/clang-mp-11
CXX_BIN=$MP/bin/clang++-mp-11
[ -x "$CC_BIN" ] || { echo "clang-mp-11 not found; install MacPorts clang-11"; exit 1; }

# LegacySupport back-fills clock_gettime, getentropy and friends. Its headers
# use #include_next, so they must be searched before the 2009 system headers.
LS_INC="-I$MP/include/LegacySupport"
LS_LIB="-L$MP/lib -lMacportsLegacySupport"

# Platform constants Snow Leopard does not provide. See BACKPORT_MATRIX.md
# rows 6-13 for what each one stands in for.
DEFS="-DUV_NO_SSM -DUV_NO_POSIX_SPAWN -DMAP_JIT=0"

CPP_ALL="$LS_INC $DEFS"

do_configure() {
  echo ">>> configure (--dest-cpu=ia32)"
  cd "$WORK" || exit 1
  CC=$CC_BIN CXX=$CXX_BIN CC_host=$CC_BIN CXX_host=$CXX_BIN \
  "$PY" ./configure \
    --prefix="$PREFIX" \
    --dest-cpu=ia32 \
    --dest-os=mac \
    --with-intl=system-icu \
    --shared-zlib \
    --shared-openssl \
    --shared-openssl-includes="$MP/libexec/openssl3/include" \
    --shared-openssl-libpath="$MP/libexec/openssl3/lib" \
    --openssl-use-def-ca-store
}

do_build() {
  cd "$WORK" || exit 1
  [ -f Makefile ] || { echo "not configured yet; run: $0 configure"; exit 1; }
  [ -f "$LOG" ] && mv "$LOG" "$LOG.prev"
  {
    echo "=== gmake -j$JOBS started $(date) ==="
    echo "CPPFLAGS: $CPP_ALL"
  } > "$LOG"
  echo "RUNNING $(date)" > "$STATUS"

  # gyp ignores environment CFLAGS. Its makefiles use
  #   CFLAGS.target ?= $(CPPFLAGS) $(CFLAGS)
  #   CFLAGS.host   ?= $(CPPFLAGS_host) $(CFLAGS_host)
  # so the flags have to arrive as make command-line variables, and the host
  # toolset needs its own copy.
  "$MP/bin/gmake" -j"$JOBS" \
    CC="$CC_BIN" CXX="$CXX_BIN" \
    CC.host="$CC_BIN" CXX.host="$CXX_BIN" \
    CC.target="$CC_BIN" CXX.target="$CXX_BIN" \
    CPPFLAGS="$CPP_ALL" CPPFLAGS_host="$CPP_ALL" \
    LDFLAGS="$LS_LIB" LDFLAGS_host="$LS_LIB" \
    >> "$LOG" 2>&1
  rc=$?
  echo "=== gmake exit $rc at $(date) ===" >> "$LOG"
  if [ $rc -eq 0 ]; then echo "BUILD-OK $(date)" > "$STATUS"
  else echo "BUILD-FAILED rc=$rc $(date)" > "$STATUS"; fi
  return $rc
}

case "${1:-build}" in
  configure) do_configure ;;
  build)
    do_build
    rc=$?
    if [ $rc -eq 0 ]; then
      echo ">>> built. version check:"
      ./out/Release/node -v || echo "(binary did not run)"
    else
      echo ">>> failed. last errors:"
      grep -nE 'error:|fatal error|Undefined symbols' "$LOG" | tail -10
    fi
    exit $rc
    ;;
  install)
    "$MP/bin/gmake" install PREFIX="$PREFIX" && "$PREFIX/bin/node" -v
    ;;
  status)
    echo "status : $(cat "$STATUS" 2>/dev/null || echo 'never run')"
    echo "objects: $(find "$WORK/out" -name '*.o' 2>/dev/null | wc -l | tr -d ' ')"
    echo "errors : $(grep -cE 'error:' "$LOG" 2>/dev/null || echo 0)"
    [ -f "$LOG" ] && { echo "--- tail ---"; grep -vE 'warning:|^ *\^|^ *~|^$' "$LOG" | tail -8; }
    ;;
  clean)     rm -rf "$WORK/out/Release/obj" "$WORK/out/Release/obj.host" "$WORK/out/Release/obj.target" ;;
  distclean) rm -rf "$WORK/out" "$WORK/config.gypi" "$WORK/config.status" "$WORK/Makefile" "$SHIM" "$LOG" "$LOG.prev" "$STATUS" ;;
  *) echo "usage: $0 [configure|build|install|status|clean|distclean]"; exit 2 ;;
esac
