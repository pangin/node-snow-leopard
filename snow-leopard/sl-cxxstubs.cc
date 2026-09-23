// libc++ ABI stubs for Mac OS X 10.6 (Snow Leopard).
//
// MacPorts clang-11 compiles against libc++ 11 headers, but the libc++ that
// gets linked on 10.6 is MacPorts libcxx 5.0.1 (/usr/lib/libc++.1.dylib).
// libc++ 11's <charconv> declares __itoa::__u32toa / __u64toa as exported
// functions living in the dylib; 5.0 predates them, so anything calling
// std::to_chars on an integer (here Node's bundled ada URL parser) fails to
// link. MacPorts solves this with its macports-libcxx port, which needs root.
//
// These match libc++ 11's src/charconv.cpp: write the decimal digits of
// `value` starting at `buffer`, no terminator, and return one past the last
// character written.
#include <charconv>
#include <cstdint>

_LIBCPP_BEGIN_NAMESPACE_STD
namespace __itoa {

char* __u32toa(uint32_t value, char* buffer) noexcept {
  char tmp[10];
  int n = 0;
  do { tmp[n++] = static_cast<char>('0' + value % 10); value /= 10; } while (value);
  while (n) *buffer++ = tmp[--n];
  return buffer;
}

char* __u64toa(uint64_t value, char* buffer) noexcept {
  char tmp[20];
  int n = 0;
  do { tmp[n++] = static_cast<char>('0' + value % 10); value /= 10; } while (value);
  while (n) *buffer++ = tmp[--n];
  return buffer;
}

}  // namespace __itoa
_LIBCPP_END_NAMESPACE_STD
