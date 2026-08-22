#!/usr/bin/env python3
"""Round-trip the sample record batch through the Arrow IPC file format,
against pyarrow, in both directions.

Direction 1: Zarr encodes the sample as a file, pyarrow opens it and checks
the schema and the values.
Direction 2: pyarrow writes the same file, Zarr opens it and verifies it.

This proves Zarr's IPC file bytes are correct against another implementation,
not merely self-consistent. It is not part of CI: it skips cleanly with exit
code 0 when pyarrow is not installed, so it never makes the build depend on an
external package. Run it with `make interop`.
"""

import ctypes
import glob
import io
import os
import sys

try:
    import pyarrow as pa
except ImportError as exc:
    print(
        f"SKIP: interop dependencies unavailable ({exc.name}); "
        "install with `uv add pyarrow` to run this test"
    )
    sys.exit(0)

EXPECTED_IDS = [1, 2, 3]
EXPECTED_FLAGS = [True, None, False]
EXPECTED_NAMES = ["a", None, "ccc"]
EXPECTED_BIOS = ["x", "yy", "zzz"]
EXPECTED_TAGS = [[1, 2], [], [3, 4, 5]]
EXPECTED_POINTS = [{"x": 1.5, "label": "a"}, None, {"x": -2.25, "label": None}]
COLUMN_NAMES = ["id", "flag", "name", "bio", "tags", "point"]


def build_schema():
    return pa.schema(
        [
            pa.field("id", pa.int32(), nullable=False),
            pa.field("flag", pa.bool_(), nullable=True),
            pa.field("name", pa.utf8(), nullable=True),
            pa.field("bio", pa.large_utf8(), nullable=False),
            pa.field("tags", pa.list_(pa.int32()), nullable=False),
            pa.field("point", pa.struct([pa.field("x", pa.float64(), nullable=False), pa.field("label", pa.utf8())]), nullable=True),
        ]
    )


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
        schema=build_schema(),
    )


def find_shared_library():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for name in ("libzarr_c.so", "libzarr_c.dylib", "zarr_c.dll"):
        hits = glob.glob(os.path.join(root, "zig-out", "**", name), recursive=True)
        if hits:
            return hits[0]
    return None


def main():
    lib_path = find_shared_library()
    if lib_path is None:
        print(
            "ERROR: zarr_c shared library not found; run `zig build c-api` first",
            file=sys.stderr,
        )
        return 1

    lib = ctypes.CDLL(lib_path)
    lib.zarr_encode_sample_file.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    lib.zarr_encode_sample_file.restype = ctypes.c_ssize_t
    lib.zarr_verify_sample_file.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    lib.zarr_verify_sample_file.restype = ctypes.c_int

    expected_columns = [
        EXPECTED_IDS,
        EXPECTED_FLAGS,
        EXPECTED_NAMES,
        EXPECTED_BIOS,
        EXPECTED_TAGS,
        EXPECTED_POINTS,
    ]

    # Direction 1: Zarr encodes the file, pyarrow opens it.
    buf = ctypes.create_string_buffer(65536)
    written = lib.zarr_encode_sample_file(ctypes.addressof(buf), len(buf))
    assert written > 0, f"zarr_encode_sample_file returned {written}"
    file_bytes = buf.raw[:written]

    with pa.ipc.open_file(pa.BufferReader(file_bytes)) as reader:
        got_schema = reader.schema
        assert reader.num_record_batches == 1, reader.num_record_batches
        batch = reader.get_batch(0)
    assert got_schema.equals(build_schema()), f"schema mismatch: {got_schema}"
    for i, expected in enumerate(expected_columns):
        got = batch.column(i).to_pylist()
        assert got == expected, f"column {i} ({COLUMN_NAMES[i]}): {got} != {expected}"
    print("PASS: Zarr file -> pyarrow read")

    # Direction 2: pyarrow writes the file, Zarr opens and verifies.
    sink = io.BytesIO()
    with pa.ipc.new_file(sink, build_schema()) as writer:
        writer.write_batch(build_reference())
    data = sink.getvalue()
    cbuf = ctypes.create_string_buffer(data, len(data))
    rc = lib.zarr_verify_sample_file(ctypes.addressof(cbuf), len(data))
    assert rc == 0, f"zarr_verify_sample_file returned {rc}"
    print("PASS: pyarrow file -> Zarr read")

    print(f"OK: IPC file round-trip verified against pyarrow {pa.__version__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
