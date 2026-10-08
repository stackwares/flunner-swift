// Adapted from @expo/serve-sim. Apache-2.0; see LICENSE and NOTICE.
// Forward the Swift ABI unchanged, including swiftself and indirect results.
// All targets are checked by SSCoreDeviceInitialize before these are called.
#if defined(__aarch64__)
.macro FORWARD name, target
.text
.p2align 2
.globl _\name
_\name:
    adrp x16, _\target@PAGE
    ldr x16, [x16, _\target@PAGEOFF]
    br x16
.endmacro
#elif defined(__x86_64__)
.macro FORWARD name, target
.text
.globl _\name
_\name:
    jmp *_\target(%rip)
.endmacro
#endif

FORWARD SSCDShared, SSCDSharedTarget
FORWARD SSCDConnection, SSCDConnectionTarget
FORWARD SSCDCreateManager, SSCDCreateManagerTarget
FORWARD SSCDAllDevices, SSCDAllDevicesTarget
FORWARD SSCDInitialized, SSCDInitializedTarget
FORWARD SSCDIdentifier, SSCDIdentifierTarget
FORWARD SSCDVisibilityAllCases, SSCDVisibilityAllCasesTarget
FORWARD SSCDImplementation, SSCDImplementationTarget

.data
.p2align 2
.globl _SSCDImplementationTu
_SSCDImplementationTu:
.long _SSCDImplementation - _SSCDImplementationTu
.long 0
