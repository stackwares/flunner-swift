# SimulatorKeyboard

Flunner's iOS keyboard adapter uses Xcode's private CoreDevice `KeyboardHIDCapability`. It fixes devices on Xcode 27 that accept touch input but silently discard the preview engine's legacy Indigo keyboard events. Android input is handled by the preview engine.

The Swift ABI shims are adapted from Expo's [serve-sim sources](https://github.com/expo/expo-device-hub/tree/cb7b7926b8e7462ea1a246be2d4948990d2c2ff8/packages/serve-sim/packages/serve-sim/Sources). The original Apache 2.0 LICENSE and NOTICE are included and copied into the app's resource bundle. This adaptation retains only the manager, capability lookup, and keyboard injection paths.

The C target resolves every required entry point dynamically before use, reads Apple's value metadata, and forwards the Swift calling convention on arm64 and x86_64. No private framework is linked at launch. Missing symbols, unsupported devices, or injection errors return `false`, allowing the caller to use the existing transport. The private API may require updates when Xcode changes its implementation; Intel builds are compile-checked, while device injection was verified on Apple Silicon with Xcode 27.

Callers serialize key pairs and release held keys when their preview closes or reloads. A generation check prevents capability lookups started before a reset from resuming input afterward.
