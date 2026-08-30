# Changelog

`pulse_slab_generator` is the optional, first-party build-time companion for
`pulse_slab`. It is released independently on pub.dev and used only as a
development dependency.

## 0.3.0-beta.2

- Fixed compatibility with the current analyzer element API used by pub.dev
  package analysis.
- Declared the native development platforms supported by the build-time
  generator. Generated layouts remain portable to all `pulse_slab` targets.

## 0.3.0-beta.1

- Added optional annotation-driven generation of Pulse Slab layouts, typed
  access helpers, serializers, deserializers, and validation hooks.
- Prepared the initial pub.dev prerelease for use as a hosted
  `dev_dependency` with `pulse_slab ^0.3.0-beta.1`.
- Added wide-layout field selections and generated indexes, while preserving
  compact mask metadata for schemas through 31 fields.
- Added `SlabFieldKind.uint64Value` for `Uint64ValueField`; legacy `uint64`
  remains the signed raw-bit-pattern `int` mapping.
