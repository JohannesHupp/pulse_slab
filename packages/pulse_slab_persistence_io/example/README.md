# File persistence example

Run this example from `packages/pulse_slab_persistence_io`:

```sh
dart run example/file_store_persistence_example.dart
```

It creates a persistent store, writes a checkpoint and an incremental update,
then reopens the journal and acknowledges the ordered replay. The temporary
journal directory is deleted before the program exits.
