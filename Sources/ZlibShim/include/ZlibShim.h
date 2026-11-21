// A persistent zlib stream for the RFB ZRLE encoding: one deflate stream lives
// for a whole connection and is flushed (Z_SYNC_FLUSH) after every rectangle,
// which Compression.framework's one-shot API cannot do. The system zlib is
// linked; this file only wraps z_stream so Swift never touches its layout.
#ifndef ZLIB_SHIM_H
#define ZLIB_SHIM_H

#include <stddef.h>

void *zs_deflate_new(void);
// Compress `in` and flush so the peer can decode it at once. Returns the
// number of bytes written to `out`, or -1 when `out` is too small or zlib failed.
long zs_deflate(void *stream, const unsigned char *in, size_t in_len,
                unsigned char *out, size_t out_cap);
void zs_deflate_free(void *stream);

void *zs_inflate_new(void);
// Decompress `in` (a flushed run from the matching deflate stream). Returns
// the number of bytes written to `out`, or -1 on error or when `out` is too small.
long zs_inflate(void *stream, const unsigned char *in, size_t in_len,
                unsigned char *out, size_t out_cap);
void zs_inflate_free(void *stream);

#endif
