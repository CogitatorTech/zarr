/*
 * Zarr C Data Interface entry points.
 *
 * These functions exchange a fixed sample record batch through the Arrow C
 * Data Interface, for verifying Zarr against another Arrow implementation.
 * The ArrowSchema and ArrowArray structs are the standard C Data Interface
 * structs; their addresses are passed as integers (uintptr_t), which is how
 * cffi and ctypes hand them across.
 *
 * The sample batch has five columns spanning several layouts: "id" (int32),
 * "flag" (boolean, with a null), "name" (utf8, with a null), "bio"
 * (large_utf8), and "tags" (list of int32).
 */
#ifndef ZARR_H
#define ZARR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Fill the caller-allocated ArrowSchema and ArrowArray at the given addresses
 * with the sample batch. The caller owns the two structs and must invoke their
 * release callbacks once done. Returns 0 on success, 1 on failure.
 */
int zarr_export_sample_batch(uintptr_t schema_addr, uintptr_t array_addr);

/*
 * Import the ArrowSchema and ArrowArray at the given addresses, release them,
 * and check the batch equals the sample. Returns 0 on a match, 1 on a
 * mismatch, and 2 when the import fails.
 */
int zarr_verify_sample_batch(uintptr_t schema_addr, uintptr_t array_addr);

#ifdef __cplusplus
}
#endif

#endif /* ZARR_H */
