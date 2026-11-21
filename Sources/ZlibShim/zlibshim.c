#include "ZlibShim.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

void *zs_deflate_new(void) {
    z_stream *s = calloc(1, sizeof(z_stream));
    if (!s) return NULL;
    if (deflateInit(s, Z_DEFAULT_COMPRESSION) != Z_OK) {
        free(s);
        return NULL;
    }
    return s;
}

long zs_deflate(void *stream, const unsigned char *in, size_t in_len,
                unsigned char *out, size_t out_cap) {
    z_stream *s = stream;
    if (!s) return -1;
    s->next_in = (Bytef *)in;
    s->avail_in = (uInt)in_len;
    s->next_out = out;
    s->avail_out = (uInt)out_cap;
    int rc = deflate(s, Z_SYNC_FLUSH);
    if (rc != Z_OK && rc != Z_BUF_ERROR) return -1;
    // Everything consumed and output space left over means the flush finished.
    if (s->avail_in != 0 || s->avail_out == 0) return -1;
    return (long)(out_cap - s->avail_out);
}

void zs_deflate_free(void *stream) {
    z_stream *s = stream;
    if (!s) return;
    deflateEnd(s);
    free(s);
}

void *zs_inflate_new(void) {
    z_stream *s = calloc(1, sizeof(z_stream));
    if (!s) return NULL;
    if (inflateInit(s) != Z_OK) {
        free(s);
        return NULL;
    }
    return s;
}

long zs_inflate(void *stream, const unsigned char *in, size_t in_len,
                unsigned char *out, size_t out_cap) {
    z_stream *s = stream;
    if (!s) return -1;
    s->next_in = (Bytef *)in;
    s->avail_in = (uInt)in_len;
    s->next_out = out;
    s->avail_out = (uInt)out_cap;
    int rc = inflate(s, Z_SYNC_FLUSH);
    if (rc != Z_OK && rc != Z_BUF_ERROR && rc != Z_STREAM_END) return -1;
    if (s->avail_in != 0) return -1;
    return (long)(out_cap - s->avail_out);
}

void zs_inflate_free(void *stream) {
    z_stream *s = stream;
    if (!s) return;
    inflateEnd(s);
    free(s);
}
