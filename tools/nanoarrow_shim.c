// Small C bridge over nanoarrow's IPC API for the differential harness in
// nanoarrow_differential.zig. Compiled together with the nanoarrow sources
// from external/nanoarrow by the `interop-nanoarrow` build step; nothing in
// the zarr library links this.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "nanoarrow/nanoarrow.h"
#include "nanoarrow/nanoarrow_ipc.h"

// Reads an Arrow IPC stream from a byte buffer, draining every batch.
// Returns 0 when nanoarrow accepts the whole stream and nonzero when it
// rejects it.
int zarr_na_try_read_stream(const uint8_t* data, int64_t len) {
  struct ArrowBuffer input;
  ArrowBufferInit(&input);
  if (ArrowBufferAppend(&input, data, len) != NANOARROW_OK) {
    ArrowBufferReset(&input);
    return 1;
  }

  struct ArrowIpcInputStream input_stream;
  if (ArrowIpcInputStreamInitBuffer(&input_stream, &input) != NANOARROW_OK) {
    ArrowBufferReset(&input);
    return 1;
  }

  struct ArrowArrayStream stream;
  if (ArrowIpcArrayStreamReaderInit(&stream, &input_stream, NULL) != NANOARROW_OK) {
    input_stream.release(&input_stream);
    return 1;
  }

  struct ArrowSchema schema;
  int status = ArrowArrayStreamGetSchema(&stream, &schema, NULL);
  if (status != NANOARROW_OK) {
    ArrowArrayStreamRelease(&stream);
    return 1;
  }
  ArrowSchemaRelease(&schema);

  int result = 0;
  while (1) {
    struct ArrowArray array;
    status = ArrowArrayStreamGetNext(&stream, &array, NULL);
    if (status != NANOARROW_OK) {
      result = 1;
      break;
    }
    if (array.release == NULL) break;  // end of stream
    ArrowArrayRelease(&array);
  }

  ArrowArrayStreamRelease(&stream);
  return result;
}

// Reads an Arrow IPC stream and writes it back out through nanoarrow's IPC
// writer. On success returns 0 and hands the caller a malloc'd buffer in
// `out`/`out_len`, released with zarr_na_free. Returns nonzero on any
// nanoarrow error.
int zarr_na_roundtrip_stream(const uint8_t* data, int64_t len, uint8_t** out,
                             int64_t* out_len) {
  *out = NULL;
  *out_len = 0;

  struct ArrowBuffer input;
  ArrowBufferInit(&input);
  if (ArrowBufferAppend(&input, data, len) != NANOARROW_OK) {
    ArrowBufferReset(&input);
    return 1;
  }

  struct ArrowIpcInputStream input_stream;
  if (ArrowIpcInputStreamInitBuffer(&input_stream, &input) != NANOARROW_OK) {
    ArrowBufferReset(&input);
    return 1;
  }

  struct ArrowArrayStream stream;
  if (ArrowIpcArrayStreamReaderInit(&stream, &input_stream, NULL) != NANOARROW_OK) {
    input_stream.release(&input_stream);
    return 1;
  }

  struct ArrowBuffer output;
  ArrowBufferInit(&output);
  struct ArrowIpcOutputStream output_stream;
  if (ArrowIpcOutputStreamInitBuffer(&output_stream, &output) != NANOARROW_OK) {
    ArrowArrayStreamRelease(&stream);
    ArrowBufferReset(&output);
    return 1;
  }

  struct ArrowIpcWriter writer;
  if (ArrowIpcWriterInit(&writer, &output_stream) != NANOARROW_OK) {
    ArrowArrayStreamRelease(&stream);
    output_stream.release(&output_stream);
    ArrowBufferReset(&output);
    return 1;
  }

  int status = ArrowIpcWriterWriteArrayStream(&writer, &stream, NULL);
  ArrowIpcWriterReset(&writer);
  ArrowArrayStreamRelease(&stream);
  if (status != NANOARROW_OK) {
    ArrowBufferReset(&output);
    return 1;
  }

  uint8_t* copy = (uint8_t*)malloc((size_t)output.size_bytes);
  if (copy == NULL) {
    ArrowBufferReset(&output);
    return 1;
  }
  memcpy(copy, output.data, (size_t)output.size_bytes);
  *out = copy;
  *out_len = output.size_bytes;
  ArrowBufferReset(&output);
  return 0;
}

void zarr_na_free(uint8_t* ptr) { free(ptr); }
