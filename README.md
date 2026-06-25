# Zarr

[![Tests](https://img.shields.io/github/actions/workflow/status/CogitatorTech/zarr/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/CogitatorTech/zarr/actions/workflows/tests.yml)
[![Zig Version](https://img.shields.io/badge/Zig-0.16.0-orange?logo=zig&labelColor=282c34)](https://ziglang.org/download/)
[![License](https://img.shields.io/badge/license-MIT-007ec6?label=license&style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/CogitatorTech/zarr/blob/main/LICENSE)

Zarr is an Apache Arrow implementation in Zig.
It provides Arrow-compatible columnar memory layouts, array builders, schemas, and record batches, with Arrow IPC and the Arrow C Data Interface planned as the library grows.
The library is pure Zig with no dependencies; it does not wrap Arrow C++ or arrow-rs.

The design priorities, in order, are correctness against the Apache Arrow format specification, explicit memory ownership, and interoperability with other Arrow implementations verified by tests.

### Status

The memory model and the first array layer are in place:

- Allocator-owned, 64-byte-aligned buffers
- LSB-numbered validity bitmaps
- The Arrow logical type system
- Fixed-width primitive arrays and their builders

The following layers are planned:

- Variable-length binary and UTF-8 arrays
- Schema and record batches
- Arrow IPC with a minimal FlatBuffers runtime
- The Arrow C Data Interface

### Getting Started

Zarr targets Zig 0.16.0. If you have the Nix package manager with flakes enabled, `make shell` drops you into a development shell with the pinned toolchain and supporting tools.

```shell
# Enter the Nix development shell (optional, provides Zig 0.16.0)
make shell
```

```shell
# Build the static library
make build

# Run the unit tests
make test

# Format the source
make format
```

The library is consumed as a Zig module named `zarr`, whose public surface is re-exported from `src/lib.zig`.

```zig
const zarr = @import("zarr");

var builder = zarr.PrimitiveArray(i32).Builder.init(allocator);
defer builder.deinit();
try builder.append(1);
try builder.appendNull();
try builder.append(3);

var array = try builder.finish();
defer array.deinit();
// array.length == 3, array.null_count == 1, array.get(1) == null
```

### Documentation

The API documentation is generated from `src/lib.zig` with Zig's built-in documentation generator.

```shell
# Generate the API documentation into docs/api
make docs

# Generate and serve the documentation on http://localhost:8085
make docs-serve
```

Run `make help` to see all available commands.

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
