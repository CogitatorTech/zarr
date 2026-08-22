#!/usr/bin/env python3
"""Round-trip the sample record batch through the Arrow C Data Interface,
against pyarrow, in both directions.

Direction 1: Zarr exports the sample, pyarrow imports it and checks the values.
Direction 2: pyarrow exports the same batch, Zarr imports it and verifies it.

This proves Zarr's C Data Interface bytes are correct against another
implementation, not merely self-consistent. It is not part of CI: it skips
cleanly with exit code 0 when pyarrow is not installed, so it never makes the
build depend on an external package. Run it with `make interop`.
"""

import ctypes
import glob
import os
import sys

try:
    import pyarrow as pa
    from pyarrow.cffi import ffi
except ImportError as exc:
    print(
        f"SKIP: interop dependencies unavailable ({exc.name}); "
        "install with `uv add pyarrow cffi` to run this test"
    )
    sys.exit(0)

EXPECTED_IDS = [1, 2, 3]
EXPECTED_FLAGS = [True, None, False]
EXPECTED_NAMES = ["a", None, "ccc"]
EXPECTED_BIOS = ["x", "yy", "zzz"]
EXPECTED_TAGS = [[1, 2], [], [3, 4, 5]]
EXPECTED_POINTS = [{"x": 1.5, "label": "a"}, None, {"x": -2.25, "label": None}]
COLUMN_NAMES = ["id", "flag", "name", "bio", "tags", "point"]


def build_reference():
    return pa.record_batch(
        [
            pa.array(EXPECTED_IDS, type=pa.int32()),
            pa.array(EXPECTED_FLAGS, type=pa.bool_()),
            pa.array(EXPECTED_NAMES, type=pa.utf8()),
            pa.array(EXPECTED_BIOS, type=pa.large_utf8()),
            pa.array(EXPECTED_TAGS, type=pa.list_(pa.int32())),
            pa.array(EXPECTED_POINTS, type=pa.struct([pa.field("x", pa.float64(), nullable=False), pa.field("label", pa.utf8())])),
        ],
        names=COLUMN_NAMES,
    )


def find_shared_library():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for name in ("libzarr_c.so", "libzarr_c.dylib", "zarr_c.dll"):
        hits = glob.glob(os.path.join(root, "zig-out", "**", name), recursive=True)
        if hits:
            return hits[0]
    return None


def addr(cdata):
    return int(ffi.cast("uintptr_t", cdata))


def main():
    lib_path = find_shared_library()
    if lib_path is None:
        print(
            "ERROR: zarr_c shared library not found; run `zig build c-api` first",
            file=sys.stderr,
        )
        return 1

    lib = ctypes.CDLL(lib_path)
    lib.zarr_export_sample_batch.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    lib.zarr_export_sample_batch.restype = ctypes.c_int
    lib.zarr_verify_sample_batch.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    lib.zarr_verify_sample_batch.restype = ctypes.c_int
    lib.zarr_verify_sample_batch_slice.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    lib.zarr_verify_sample_batch_slice.restype = ctypes.c_int

    # Compare by value, not by full schema equality: field names on nested
    # children and nullability metadata are not what this test asserts.
    expected_columns = [
        EXPECTED_IDS,
        EXPECTED_FLAGS,
        EXPECTED_NAMES,
        EXPECTED_BIOS,
        EXPECTED_TAGS,
        EXPECTED_POINTS,
    ]

    # Direction 1: Zarr exports, pyarrow imports.
    c_schema = ffi.new("struct ArrowSchema*")
    c_array = ffi.new("struct ArrowArray*")
    rc = lib.zarr_export_sample_batch(addr(c_schema), addr(c_array))
    assert rc == 0, f"zarr_export_sample_batch returned {rc}"
    batch = pa.RecordBatch._import_from_c(addr(c_array), addr(c_schema))
    assert batch.num_rows == len(EXPECTED_IDS), batch.num_rows
    for i, expected in enumerate(expected_columns):
        got = batch.column(i).to_pylist()
        assert got == expected, f"column {i} ({COLUMN_NAMES[i]}): {got} != {expected}"
    print("PASS: Zarr export -> pyarrow import")

    # Direction 2: pyarrow exports, Zarr imports and verifies.
    batch2 = build_reference()
    c_schema2 = ffi.new("struct ArrowSchema*")
    c_array2 = ffi.new("struct ArrowArray*")
    batch2._export_to_c(addr(c_array2), addr(c_schema2))
    rc = lib.zarr_verify_sample_batch(addr(c_schema2), addr(c_array2))
    assert rc == 0, f"zarr_verify_sample_batch returned {rc}"
    print("PASS: pyarrow export -> Zarr import")

    # Direction 3: pyarrow exports a slice, which arrives with a non-zero
    # offset; Zarr must honor it on import.
    sliced = build_reference().slice(1, 2)
    c_schema3 = ffi.new("struct ArrowSchema*")
    c_array3 = ffi.new("struct ArrowArray*")
    sliced._export_to_c(addr(c_array3), addr(c_schema3))
    rc = lib.zarr_verify_sample_batch_slice(addr(c_schema3), addr(c_array3))
    assert rc == 0, f"zarr_verify_sample_batch_slice returned {rc}"
    print("PASS: pyarrow sliced export -> Zarr import")

    print(f"OK: C Data Interface round-trip verified against pyarrow {pa.__version__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
