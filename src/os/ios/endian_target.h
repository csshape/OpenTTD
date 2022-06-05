#ifndef ENDIAN_H
#define ENDIAN_H
#ifdef __BIG_ENDIAN__
#define TTD_ENDIAN TTD_BIG_ENDIAN
#else
#define TTD_ENDIAN TTD_LITTLE_ENDIAN
#endif
#endif
