/// Optional build-time generation for Pulse Slab record layouts.
library;

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/slab_layout_generator.dart';

/// Creates builders for `@SlabRecord` declarations.
Builder pulseSlabLayoutBuilder(BuilderOptions options) =>
    SharedPartBuilder(<Generator>[SlabLayoutGenerator()], 'pulse_slab');
