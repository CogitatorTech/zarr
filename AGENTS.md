# AGENTS.md

This file provides guidance to coding agents collaborating on this repository.

## Mission

Zarr is an Apache Arrow implementation in Zig.
It provides Arrow-compatible columnar memory layouts, array builders, schemas, and record batches, with Arrow IPC and the Arrow C Data Interface
(planned as the library grows).
The library is pure Zig with no dependencies; it does not wrap Arrow C++ or Rust.

Priorities, in order:

1. Correctness and alignment with the Apache Arrow format specification.
2. Explicit memory ownership: allocators are passed in, and every `init` has a matching `deinit`.
3. Interoperability with other Arrow implementations, verified by tests rather than assumed.

## Core Rules

- Use English for code, comments, docs, tests, and commit messages.
- Target Zig 0.16.0. Prefer the Makefile, which invokes the pinned compiler; the `zig` on PATH may be a different version.
- Prefer focused fixes over broad refactoring.
- Keep the library dependency-free. Do not add entries to `build.zig.zon` dependencies unless the task explicitly calls for them.
- When layout or format questions come up, the Arrow format specification is the authority.

## Writing Style

- Write in simple, plain English. Use short sentences and everyday words.
- Use Oxford commas in inline lists: "a, b, and c" not "a, b, c".
- Do not use em dashes. Restructure the sentence, or use a colon or semicolon instead.
- Avoid colorful adjectives and adverbs. Write "array builder" not "powerful array builder".
- Prefer using noun phrases for checklist items, not imperative verbs. Write "offset monotonicity validation" not "validate offset monotonicity".
- Headings in Markdown files must be in title case: "Build from Source" not "Build from source". Minor words
  (a, an, the, and, but, or, for, in, on, at, to, by, of, from, and with) stay lowercase unless they are the first word.
- Write correct and complete sentences.
- Avoid made-up words, abbreviations, and colons in the middle of sentences.
- Don't use pretentious language and made-up words.

## Repository Layout

- `src/lib.zig`: root module and public re-exports; the single public API surface.
- `src/zarr/`: implementation modules.
- `src/zarr/buffer.zig`: `Buffer`, an allocator-owned, 64-byte-aligned byte buffer.
- `src/zarr/bitmap.zig`: `Bitmap`, the LSB-numbered validity bitmap.
- `src/zarr/datatype.zig`: `DataType`, the Arrow logical type system.
- `src/zarr/primitive_array.zig`: `PrimitiveArray`, a fixed-width primitive array and its builder.
- `src/zarr/ipc/`: the Arrow IPC layer, layered as FlatBuffers runtime, message framing, schema and record batch serialization, and the stream and file formats.
- `test/interop/`: pyarrow round-trip scripts run by `make interop`; they skip cleanly when pyarrow is absent.
- `tools/`: development binaries wired through `build.zig`, such as the IPC corpus check; they are not part of the library.
- `external/`: optional git submodules for differential testing (arrow-testing and nanoarrow). Nothing under `src/` may import them, and every
  target that needs them skips cleanly when they are not initialized (`git submodule update --init`), so the library itself stays dependency-free.
- `build.zig`: module definition, static library artifact, and the `test` and `docs` steps.
- `build.zig.zon`: package metadata; minimum Zig version 0.16.0.
- `Makefile`: development workflow wrapper around `zig build`.
- `flake.nix`: Nix development shell that pins the Zig 0.16.0 toolchain.
- `.github/workflows/`: CI workflows.

New modules go under `src/zarr/`, are imported and re-exported from `src/lib.zig`, and carry their tests in the same file.
`src/lib.zig` runs everything through `std.testing.refAllDecls`.

## Architecture Notes

### Memory Model

Every Arrow array reduces to a small set of buffers: a validity bitmap plus type-specific value and offset buffers.
Buffers are 64-byte aligned per the Arrow spec recommendation. Ownership is explicit: structs store the allocator they were created with, and `deinit`
frees and poisons the value.
No global state, no hidden allocations.

### Spec Alignment

Layout decisions follow the Arrow columnar format: LSB bit numbering for bitmaps, set bit means valid, i32 offsets for `binary`/`utf8`, and buffer
ordering as defined by the spec.
When adding a type or layout, check the spec first and mirror its terminology in names and doc comments.

### Component Boundaries

Modules form an acyclic dependency graph.
Lower layers, such as buffer and bitmap, never import higher layers, and sibling modules do not import each other.
When adding a module, confirm it introduces no cycle.
`src/lib.zig` is the single public API surface.
Re-export new public declarations there.
The flat aliases, such as `zarr.Buffer`, are the canonical form, and the module namespaces, such as `zarr.buffer`, are secondary.
Cross-module access goes through published methods, not another type's fields.
Where raw buffer access is intentional for performance, note it in a doc comment.

### Planned Layers

Memory model, arrays and builders, schema and record batches, IPC with a minimal FlatBuffers runtime, and the C Data Interface.
Keep new work within the current phase unless the task says otherwise; interop with pyarrow is the acceptance bar for the IPC milestone.

The memory model, the array layer, schema, and record batches are in place, along with a type-erased `ArrayData` bridge (`toData`/`fromData`) that every array
type round-trips through. The C Data Interface (`src/zarr/c_data.zig`) exports and imports types, fields, arrays, and record batches. IPC is in place under
`src/zarr/ipc/`: a minimal FlatBuffers runtime, message framing, schema and record batch serialization, and the stream and file formats. Both the C Data
Interface and IPC are interop-proven against pyarrow in both directions. `make interop` runs the scripts under `test/interop/`, and fixture tests inside the
IPC modules pin pyarrow-written bytes without a network or Python dependency. Not yet implemented: writing dictionary-encoded schemas, dictionary deltas, body compression, the C interface for dictionary types, and the spec types
missing from `DataType`: interval, map, union, and the view layouts. Readers report these as unsupported errors instead of guessing.
Temporal coverage is complete (date, time, duration, and timestamps with or without a timezone), and so are decimals and the fixed-size layouts.
Dictionary-encoded data reads end to end: IPC streams and files deliver dictionary batches, and decoded columns carry their dictionary values.

## Zig Conventions

- Format with `zig fmt`; `make format` applies formatting, and `zig fmt --check` verifies without writing.
- Tests live next to the code they cover in the same file, using `std.testing`.
- Use `std.testing.allocator` in tests so leaks fail the test.
- Assert internal invariants with `std.debug.assert`; return errors for conditions the caller can cause.
- Prefer `comptime` generics (as in `DataType.fromZigType`) over runtime dispatch where the type is known at compile time.
- Public declarations get `///` doc comments; modules get a `//!` header explaining their place in the Arrow model.

## Required Validation

Run the narrowest relevant checks, then expand if the change is wide.

| Area       | Command                                       | Use When                               |
|------------|-----------------------------------------------|----------------------------------------|
| Tests      | `make test`                                   | Any code change                        |
| Formatting | `zig fmt --check src build.zig build.zig.zon` | Any code change                        |
| Build      | `make build`                                  | `build.zig` or `build.zig.zon` changed |
| Docs       | `make docs`                                   | Public API doc comments changed        |
| Corpus     | `make corpus`                                 | IPC decode paths changed (optional; skips without the arrow-testing submodule) |
| Differential | `make interop-nanoarrow`                    | IPC read or write paths changed (optional; skips without the nanoarrow submodule) |
| Golden     | `make golden`                                 | IPC decode paths or `DataType` changed (optional; skips without the arrow-testing submodule) |

Minimum expectations:

- Code changes: `make test`, and formatting verified with `zig fmt --check` or applied with `make format`.
- Build wiring changes: `make build` and `make test`.
- Docs-only changes: no build required, but check links and plan checkboxes.

If `make` is unavailable, the equivalent direct commands are `zig build test` and `zig fmt --check src build.zig build.zig.zon`, run with a Zig 0.16.0
compiler.

## Testing Expectations

- Every public function gets at least one test in its own file.
- Cover boundary conditions typical of columnar layouts: zero-length arrays, lengths not divisible by 8 for bitmaps, and all-null or no-null cases.
- Memory correctness is part of correctness: tests must free what they allocate, since `std.testing.allocator` reports leaks as failures.
- Once IPC lands, round-trip fixtures against pyarrow are the interop bar; do not make CI depend on remote resources.

## Change Design Checklist

Before coding:

1. Task classification (memory model, arrays and builders, schema, IPC, C ABI, build wiring, docs, or tests).
2. Arrow spec check for any layout, naming, or semantics decision.

Before submitting:

1. `make test` passes locally and the source is formatted (`zig fmt --check`), or any gaps are explicitly called out.
2. New public API is re-exported from `src/lib.zig` and covered by tests.

## Commit and PR Hygiene

- Keep commits scoped to one logical change.
- PR descriptions should include:
    1. Behavioral change summary.
    2. Validation runs locally.
    3. Which plan phase the change belongs to.
