// Instantiated by hand from external/nanoarrow's nanoarrow_config.h.in,
// which CMake would normally generate; the values match the pinned
// apache-arrow-nanoarrow-0.9.0 tag, with no symbol namespace. The template
// is Apache License 2.0, Copyright the Apache Software Foundation.

#ifndef NANOARROW_CONFIG_H_INCLUDED
#define NANOARROW_CONFIG_H_INCLUDED

#define NANOARROW_VERSION_MAJOR 0
#define NANOARROW_VERSION_MINOR 9
#define NANOARROW_VERSION_PATCH 0
#define NANOARROW_VERSION "0.9.0"

#define NANOARROW_VERSION_INT                                        \
  (NANOARROW_VERSION_MAJOR * 10000 + NANOARROW_VERSION_MINOR * 100 + \
   NANOARROW_VERSION_PATCH)

#if !defined(NANOARROW_CXX_NAMESPACE)
#define NANOARROW_CXX_NAMESPACE nanoarrow
#endif

#define NANOARROW_CXX_NAMESPACE_BEGIN namespace NANOARROW_CXX_NAMESPACE {
#define NANOARROW_CXX_NAMESPACE_END }

#endif
