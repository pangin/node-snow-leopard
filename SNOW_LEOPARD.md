# Mac OS X Snow Leopard backport

This branch backports Node.js 20.19.5 to Mac OS X 10.6.8 on 32-bit Intel Macs.
It targets Darwin 10.8.0 (`i386`) and is intended for MacPorts installed under
`/opt/local`.

Node.js has published no 32-bit macOS binary since v0.12 (February 2017), and
the tree pins a 10.15 deployment target, so the stock source will not even
configure on 10.6. MacPorts still lists `i386` in `lang/nodejs20`'s
`supported_archs` and carries an `--dest-cpu=ia32` branch, which is the basis
this work builds on.

## Target

- Mac OS X 10.6.8 / Darwin 10.8.0 / `i386`
- Intel Core Duo 1.83 GHz, 2 cores, no 64-bit support (`hw.cpu64bit_capable: 0`)
- 2 GB RAM

## Tested toolchain

- MacPorts 2.12.6
- `clang-11 @11.1.0_9+defaultlibcxx+emulated_tls`
- `gmake @4.4.1_1`
- `legacy-support @1.5.2_0`
- `libcxx @5.0.1_5+emulated_tls+universal`
- `icu @78.3_1`
- `openssl3 @3.6.4_0`
- `zlib @1.3.2_0`
- `python314 @3.14.7_0`
- `pkgconfig @0.29.2_0`

Install the build dependencies with MacPorts:

```sh
sudo /opt/local/bin/port install clang-11 gmake legacy-support icu openssl3 zlib python314 pkgconfig
```

MacPorts leaves the plain `python3` name to `port select`. The build script
creates its own shim instead, so the `#!/usr/bin/env python3` scripts in the
tree (`gyp-mac-tool` among them) resolve without touching the MacPorts prefix.

## Build

```sh
./build-snow-leopard.sh configure
./build-snow-leopard.sh
~/.local/node20/bin/node -v
```

`build-snow-leopard.sh` is resumable: re-running it continues an interrupted
build rather than starting over.

## Compatibility changes

- Remove the `MACOSX_DEPLOYMENT_TARGET: 10.15` pin from `common.gypi`. It
  forces every target in the tree to reject 10.6. MacPorts' `lang/nodejs20`
  drops the same line.
- Widen `configure`'s interpreter allow-list, which stops at 3.13, to accept
  Python 3.14.
- Replace `nodedownload.py`'s `FancyURLopener`/`URLopener` imports with a stub.
  Python 3.14 removed both. The module is only reached when fetching a bundled
  ICU, which this build does not do (`--with-intl=system-icu`).
- Compile out libuv's source-specific multicast support. `ip_mreq_source`,
  `group_source_req`, `IP_ADD_SOURCE_MEMBERSHIP` and `MCAST_JOIN_SOURCE_GROUP`
  arrived in 10.7. libuv already returns `UV_ENOSYS` for platforms without
  them, so this only selects that existing path.
- Select libuv's fork/exec spawn path. The Apple `posix_spawn` path needs
  `posix_spawn_file_actions_addinherit_np` and `POSIX_SPAWN_CLOEXEC_DEFAULT`,
  both 10.7 and both absent from Snow Leopard's `libSystem`. libuv's own
  comment describes that path as a workaround for a macOS Big Sur regression
  where fork/exec became slow for processes with many `MAP_JIT` pages, which
  does not apply here.
- Disable V8's system instrumentation. It includes `<os/signpost.h>` (10.14)
  and compiles `recorder-mac.cc`; turning the feature off drops both.
- Define `MAP_JIT` as 0. The flag is 10.14 and exists for the hardened
  runtime, which 10.6 does not have, so the bitwise OR becomes a no-op.
- Define `VM_FLAGS_OVERWRITE` as `0x4000`. Snow Leopard's
  `<mach/vm_statistics.h>` describes the flag in a comment but never defines
  it. The kernel does honour it: a `mach_vm_remap(VM_FLAGS_FIXED | 0x4000)`
  onto a live mapping returns `KERN_SUCCESS`, lands on the requested address
  and aliases the source pages. This was verified on the target before the
  define was added rather than assumed from the value.
- Supply `getsectiondata()` in terms of `getsectdatafromheader()`. The former
  is 10.7; `nm` on 10.6's `libSystem` shows only `addclose`, `adddup2` and
  `addopen`. Both functions return the section's unslid `vmaddr`, and V8 adds
  `_dyld_get_image_vmaddr_slide()` itself, so the substitution is exact.
- Correct V8's `#if V8_HOST_ARCH_I32` guard in `platform-darwin.cc`. That macro
  occurs exactly once in the V8 tree, at that `#if`, and is defined nowhere
  (the real name is `V8_HOST_ARCH_IA32`). A 32-bit build therefore took the
  64-bit branch and reinterpreted a `mach_header` as a `mach_header_64`. The
  guard now tests the compiler's own `__i386__` predefine.
- Spell `offset_imm` as `uintptr_t` throughout V8's IA-32 Liftoff backend
  (`liftoff-assembler-ia32.h`). The shared declarations in
  `liftoff-assembler.h` use `uintptr_t`; the ia32 definitions used `uint32_t`.
  On Darwin/i386 `uintptr_t` is `unsigned long`, a distinct type from
  `unsigned int` at the same 32-bit width, so all eleven out-of-line member
  definitions failed to match their declarations. Linux and Windows i386
  define `uintptr_t` as `unsigned int`, which is why upstream, and the
  otherwise identical ARM backend, never see this.

## Build notes

- gyp ignores environment `CFLAGS`. Its generated makefiles set
  `CFLAGS.target ?= $(CPPFLAGS) $(CFLAGS)` and
  `CFLAGS.host ?= $(CPPFLAGS_host) $(CFLAGS_host)`, so the LegacySupport
  include path has to arrive as `gmake` command-line variables, and separately
  for the host toolset. Passing it in the environment silently does nothing,
  which presents as a missing `clock_gettime`.
- Snow Leopard's `tar` predates `.tar.xz`. Use MacPorts `bsdtar` to unpack the
  release tarball.
- BSD `sed` requires the `-i` suffix to be attached (`-i.bak`). Writing
  `sed -i -E` consumes `-E` as the backup suffix and silently disables
  extended regular expressions.
- Detach the build from the login session with `nohup ... < /dev/null`.
  Redirecting only stdout is not enough: with stdin still attached to an SSH
  pipe, `gmake` sleeps the moment that session closes, leaving the process
  tree alive but idle.

## State

The build is in progress on the target and has not yet produced a binary.

`configure` completes and records `target_arch: ia32` and `host_arch: ia32`
with system ICU 78, shared OpenSSL 3 and shared zlib. With every patch above
applied, the tree compiles through libuv, c-ares, googletest, simdutf, V8's
base library and the first host-tool link, and has passed the IA-32 Liftoff
WebAssembly baseline compiler that stopped the previous attempt. Object count
at the time of writing: 1410 and rising, with no errors in the current run.

Nothing here is claimed as a working Node.js until `node -v` runs on the
target. The two remaining unknowns are whether V8's IA-32 code generation
completes under a 2 GB, 32-bit address space, and whether the final link fits.
