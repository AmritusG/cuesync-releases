# CZlib

Vendored zlib source, version **1.3.1**, downloaded from
<https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz>.

The full library is vendored (not just the inflate side) so `deflate` is
available to the zlib parity/round-trip test alongside the `inflate` path
that `Support/Zlib.swift` uses for Engine DJ `quickCues` blob decompression.
Vendoring means Windows/Linux/ARM builds need no system zlib install.

`Support/Zlib.swift` drives `inflateInit2(&strm, -15)` (negative windowBits
= raw DEFLATE, no zlib/gzip header) to match Apple's
`compression_decode_buffer(..., COMPRESSION_ZLIB)` semantics on Darwin.

To upgrade: download a newer release tarball from
<https://github.com/madler/zlib/releases>, replace the `.c`/`.h` files here
(keep `zlib.h`/`zconf.h` in `include/`), and update the version above.
