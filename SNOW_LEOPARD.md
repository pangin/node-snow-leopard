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

On the target the build takes days. Over SSH, run it under the supervisor
instead, which detaches into its own session and restarts the build if it
goes quiet without finishing:

```sh
/opt/local/bin/python3.14 snow-leopard/supervise.py --daemon
tail -f snow-leopard-supervise.log
```

It stops on success or on a real compile failure; it does not retry errors.

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
- Add a Mach-O branch to V8's IA-32 `push_registers_asm.cc`. The file only
  distinguishes Win32 from "everything else" and emits the ELF directives
  `.type` and `.hidden` for the latter, which the Darwin assembler rejects
  as unknown. Mach-O needs the underscore-prefixed symbol and
  `.private_extern`, exactly as the x64 file's existing Apple branch does.
  The cdecl body is unchanged.
- Supply `std::__itoa::__u32toa` and `__u64toa` at link time
  (`snow-leopard/sl-cxxstubs.cc`). clang-11 compiles against libc++ 11
  headers, whose `<charconv>` declares these as functions exported by the
  libc++ dylib, but the libc++ linked on 10.6 is MacPorts `libcxx` 5.0.1,
  which exports none of them (`nm` finds no `__itoa` symbol). Any
  `std::to_chars` on an integer therefore fails to link; in Node that is the
  bundled ada URL parser, so `cctest`, `node_mksnapshot` and `node` itself
  all fail. The stubs follow libc++ 11's `src/charconv.cpp` (decimal digits,
  no terminator, return one past the end) and were checked against
  `snprintf` on 0 and the 32- and 64-bit maxima. MacPorts' own answer is its
  `macports-libcxx` port, which `lang/nodejs20` depends on but which needs
  root.

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
- **The 32-bit address space shows up at the archive step, not at compile
  time.** With the default `-gdwarf-2 -g`, V8's `libv8_base_without_compiler.a`
  is 3.6 GB, and Apple's `libtool` buffers the whole output archive in memory:
  `can't vm_allocate() buffer for output file ... ((os/kern) no space
  available)`. Debug information is most of that size, so build with `-g0`
  (`build-snow-leopard.sh` does). If a tree was already built with `-g`,
  adding `-g0` recompiles everything, about ten hours on the target. Stripping
  the objects (`strip -S`) shrinks the archives at once, but it does not save
  that recompile. The same limit would otherwise hit the `mksnapshot` and
  final `node` links.
- **gyp's makefiles track command lines, not only timestamps.** Each target's
  last command is recorded in `out/Release/.deps/<abs path>.d`, and
  `command_changed` reruns the rule when it differs. Changing `CPPFLAGS`
  therefore recompiles every object. Changing `LDFLAGS` relinks every
  executable, including the code generators (`torque`,
  `bytecode_builtins_list_generator`, `node_js2c`, `mksnapshot`). A relinked
  generator is newer than its outputs, so its action reruns and everything
  that includes those outputs recompiles; for `torque` that is over 900
  objects. When only link inputs change, as with the `sl-cxxstubs.o` fix,
  the generators' outputs are byte-identical. Stop the build right after
  the new link command is recorded, give every file under `out/Release` one
  timestamp (`find out/Release -type f -exec touch -t <stamp> {} +`), and
  restart: only the rules whose command really changed run. `make -n` is no
  guide here, because gyp's `FORCE_DO_CMD` prerequisites make a dry run
  report a full rebuild.
- **Detaching from SSH.** Redirecting only stdout is not enough: with stdin
  still attached to an SSH pipe, `gmake` sleeps the moment that session
  closes, leaving the process tree alive but idle. `nohup ... < /dev/null`
  fixed that, yet on a later run `gmake` was again found sleeping with no
  children and a log 65 hours stale, with no error recorded. 10.6 has no
  `setsid(1)`, so `snow-leopard/supervise.py` calls `os.setsid()` itself and
  also restarts the build when its log goes quiet with nothing compiling. A
  tree stopped on purpose with `kill -STOP` (state `T`) is not treated as a
  stall.

## Verified behavior

Built, installed and run on the target (Mac OS X 10.6.8, Darwin 10.8.0,
Core Duo, 2 GB) on 2026-09-24:

```
$ file ~/.local/node20/bin/node
Mach-O executable i386
$ node -v
v20.19.5
$ node -e 'console.log(process.arch, process.platform, os.release(), ...)'
ia32 darwin 10.8.0
```

- `process.versions`: V8 11.3.244.8-node.30, OpenSSL 3.6.4, ICU 78.3.
- `crypto` (SHA-256), `zlib` (gzip) and `Intl` (locale `en-US`) work.
- Node's own HTTPS client completes a TLS handshake with `api.github.com`
  and gets a 200.
- npm 10.8.2, npx and corepack 0.33.0 are installed and run; `npm view`
  reaches the public registry over TLS.
- The whole tree builds: V8 including `mksnapshot` and snapshot generation,
  `node_mksnapshot`, `cctest`, `embedtest` and `node` (38.9 MB).
- `otool -L` resolves every library: legacy-support, MacPorts zlib,
  OpenSSL 3 and ICU 78, CoreFoundation, libSystem, and libc++ / libc++abi
  5.0.1.

Not yet exercised on the target: Node's own test suite (`cctest` built but
not run), and long-running workloads. Real programs running on this build are
tracked in [snow-leopard-devenv](https://github.com/pangin/snow-leopard-devenv).

Wall-clock on this hardware: the complete compile is about ten hours with
`-g0` on two 1.83 GHz cores. It took several days of attempts in practice,
because every gap above was found by a failed build.
