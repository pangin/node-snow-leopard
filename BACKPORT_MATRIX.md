# Backport matrix

## Platform gaps

Each row is an API or build assumption the stock Node.js 20.19.5 tree makes
that Mac OS X 10.6.8 does not satisfy. "Introduced" is the macOS release that
first shipped the thing being relied on.

| # | Gap | Introduced | Component | Resolution |
| ---: | --- | --- | --- | --- |
| 1 | `MACOSX_DEPLOYMENT_TARGET` pinned to 10.15 | n/a | `common.gypi` | Pin removed |
| 2 | `configure` rejects Python 3.14 | n/a | `configure` | Allow-list widened |
| 3 | `urllib.FancyURLopener` removed in Python 3.14 | n/a | `nodedownload.py` | Import stubbed; path unused with system ICU |
| 4 | `clock_gettime`, `CLOCK_MONOTONIC` | 10.12 | libuv | MacPorts `legacy-support` |
| 5 | `getentropy` | 10.12 | libuv | MacPorts `legacy-support` |
| 6 | `ip_mreq_source`, `IP_ADD_SOURCE_MEMBERSHIP` | 10.7 | libuv | libuv's existing `UV_ENOSYS` path |
| 7 | `group_source_req`, `MCAST_JOIN_SOURCE_GROUP` | 10.7 | libuv | libuv's existing `UV_ENOSYS` path |
| 8 | `posix_spawn_file_actions_addinherit_np` | 10.7 | libuv | libuv's fork/exec fallback |
| 9 | `POSIX_SPAWN_CLOEXEC_DEFAULT` | 10.7 | libuv | libuv's fork/exec fallback |
| 10 | `<os/signpost.h>` | 10.14 | V8 libplatform | System instrumentation disabled |
| 11 | `MAP_JIT` | 10.14 | V8 platform-posix | Defined as 0; no hardened runtime on 10.6 |
| 12 | `VM_FLAGS_OVERWRITE` macro absent from header | n/a | V8 platform-darwin | Defined as `0x4000` after runtime verification |
| 13 | `getsectiondata()` | 10.7 | V8 platform-darwin | Expressed via `getsectdatafromheader()` |
| 14 | `V8_HOST_ARCH_I32` never defined (upstream defect) | n/a | V8 platform-darwin | Guard tests `__i386__` |
| 15 | `python3` name not on `PATH` | n/a | gyp toolchain | Shim in the build script |
| 16 | `tar` cannot read `.tar.xz` | n/a | host tooling | MacPorts `bsdtar` |

Rows 4 and 5 need no source change: MacPorts `legacy-support` supplies them,
provided its include directory precedes the 2009 system headers and the
runtime library is linked.

Row 14 is a defect in upstream V8 rather than a platform gap. The macro
`V8_HOST_ARCH_I32` appears exactly once in the V8 tree, at the `#if` that
selects between 32-bit and 64-bit Mach-O headers, and is defined in no header.
Any 32-bit macOS build therefore takes the 64-bit branch. The condition has no
effect on the platforms upstream still builds, which is why it survives.

Row 12 was verified rather than inferred. A test program on the target called
`mach_vm_remap` with `VM_FLAGS_FIXED | 0x4000` onto an already-mapped region:
it returned `KERN_SUCCESS`, landed on the requested address, and reads through
the destination saw the source's contents. The header's own comment documents
the flag; only the `#define` is missing.

## Release coverage

| Node.js line | Status |
| --- | --- |
| 20.19.5 | Patched; build in progress on the target |
| 20.x (other) | Not attempted |
| 22.x, 24.x | Not attempted |
| 18.x and earlier | Not attempted |

Only 20.19.5 has been worked on. MacPorts lists `i386` in `supported_archs`
for `nodejs18` through `nodejs22`, so those lines are plausible candidates,
but none has been configured or compiled here and none is claimed.

A version is counted as ported only after its `node` binary compiles, links,
and reports its version when run on the 10.6.8 i386 target. A tree that merely
patches and configures is not a completed backport.

## Known limits

- `uv_udp_set_source_membership()` returns `UV_ENOSYS`. Source-specific
  multicast is unavailable, which is the same behaviour libuv gives on
  OpenBSD, NetBSD and Android.
- V8 system instrumentation is off, so `--enable-system-instrumentation` has
  no effect. This only removes Instruments signpost output.
- Child processes go through fork/exec rather than `posix_spawn`. On this
  hardware that is the appropriate path regardless.
