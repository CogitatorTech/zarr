#!/usr/bin/env python3
"""Round-trip the sample record batch through the Arrow IPC stream format,
against pyarrow, in both directions.

Direction 1: Zarr encodes the sample as a stream, pyarrow reads it and checks
the schema and the values.
Direction 2: pyarrow writes the same stream, Zarr reads it and verifies it.

This proves Zarr's IPC stream bytes are correct against another
implementation, not merely self-consistent. It is not part of CI: it skips
cleanly with exit code 0 when pyarrow is not installed, so it never makes the
build depend on an external package. Run it with `make interop`.
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
    lib.zarr_encode_sample_stream.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    lib.zarr_encode_sample_stream.restype = ctypes.c_ssize_t
    lib.zarr_verify_sample_stream.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    lib.zarr_verify_sample_stream.restype = ctypes.c_int

    expected_columns = [
        EXPECTED_IDS,
        EXPECTED_FLAGS,
        EXPECTED_NAMES,
        EXPECTED_BIOS,
        EXPECTED_TAGS,
        EXPECTED_POINTS,
    ]

    # Direction 1: Zarr encodes the stream, pyarrow reads it.
    buf = ctypes.create_string_buffer(65536)
    written = lib.zarr_encode_sample_stream(ctypes.addressof(buf), len(buf))
    assert written > 0, f"zarr_encode_sample_stream returned {written}"
    stream_bytes = buf.raw[:written]

    with pa.ipc.open_stream(pa.BufferReader(stream_bytes)) as reader:
        got_schema = reader.schema
        batches = list(reader)
    assert got_schema.equals(build_schema()), f"schema mismatch: {got_schema}"
    assert len(batches) == 1, f"expected 1 batch, got {len(batches)}"
    for i, expected in enumerate(expected_columns):
        got = batches[0].column(i).to_pylist()
        assert got == expected, f"column {i} ({COLUMN_NAMES[i]}): {got} != {expected}"
    print("PASS: Zarr stream -> pyarrow read")

    # Direction 2: pyarrow writes the stream, Zarr reads and verifies.
    sink = io.BytesIO()
    with pa.ipc.new_stream(sink, build_schema()) as writer:
        writer.write_batch(build_reference())
    data = sink.getvalue()
    cbuf = ctypes.create_string_buffer(data, len(data))
    rc = lib.zarr_verify_sample_stream(ctypes.addressof(cbuf), len(data))
    assert rc == 0, f"zarr_verify_sample_stream returned {rc}"
    print("PASS: pyarrow stream -> Zarr read")

    print(f"OK: IPC stream round-trip verified against pyarrow {pa.__version__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
