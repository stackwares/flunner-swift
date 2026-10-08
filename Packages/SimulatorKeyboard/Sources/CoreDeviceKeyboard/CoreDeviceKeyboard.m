// Adapted from @expo/serve-sim. Apache-2.0; see LICENSE and NOTICE.
#import "CoreDeviceKeyboard.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <ptrauth.h>

// Targets for the register-preserving trampolines in CoreDeviceTrampolines.S.
void *SSCDSharedTarget, *SSCDConnectionTarget, *SSCDCreateManagerTarget;
void *SSCDAllDevicesTarget, *SSCDInitializedTarget, *SSCDIdentifierTarget;
void *SSCDImplementationTarget;
void *SSCDVisibilityAllCasesTarget;
extern int32_t SSCDImplementationTu[2];
static void *framework;

static bool resolve(void **destination, const char *symbol) {
    *destination = dlsym(framework, symbol);
    return *destination != NULL;
}

bool SSCoreDeviceInitialize(void) {
    static dispatch_once_t once;
    static bool available;
    dispatch_once(&once, ^{
        framework = dlopen("/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice", RTLD_NOW | RTLD_GLOBAL);
        if (!framework) return;
        bool found = true;
        found &= resolve(&SSCDSharedTarget, "$s10CoreDevice0B7ManagerC6sharedACvgZ");
        found &= resolve(&SSCDConnectionTarget, "$s10CoreDevice0aB7ServiceV16sharedConnectionAA0abcE0_pvgZ");
        found &= resolve(&SSCDCreateManagerTarget, "$s10CoreDevice0B7ManagerC17serviceConnection07allowedB17VisibilityClassesAcA0ab7ServiceE0_p_ShyAA0bG5ClassOGtcfC");
        found &= resolve(&SSCDAllDevicesTarget, "$s10CoreDevice0B7ManagerC10allDevicesSayAA06RemoteB0CGyF");
        found &= resolve(&SSCDInitializedTarget, "$s10CoreDevice0B7ManagerC16fullyInitializedSbvgTj");
        found &= resolve(&SSCDIdentifierTarget, "$s10CoreDevice06RemoteB0C16deviceIdentifier10Foundation4UUIDVvgTj");
        found &= resolve(&SSCDVisibilityAllCasesTarget, "$s10CoreDevice0B15VisibilityClassO8allCasesSayACGvgZ");
        found &= resolve(&SSCDImplementationTarget, "$s10CoreDevice06RemoteB0C17getImplementation3for12ProtocolTypeQzAA22CapabilityStaticMemberVyxG_tYaKAA0bI0RzlFTj");
        int32_t *implementation = dlsym(framework, "$s10CoreDevice06RemoteB0C17getImplementation3for12ProtocolTypeQzAA22CapabilityStaticMemberVyxG_tYaKAA0bI0RzlFTjTu");
        if (!found || !implementation) return;
        // Swift allocates the callee's async context using this descriptor.
        // Forwarding with a guessed size corrupts the task's allocation stack.
        SSCDImplementationTu[1] = implementation[1];
        available = true;
    });
    return available;
}

void *SSCoreDeviceSymbol(const char *name) {
    return SSCoreDeviceInitialize() ? dlsym(framework, name) : NULL;
}

void SSCoreDeviceRetainBridgeObject(void *object) {
    typedef void *(*Retain)(void *);
    ((Retain)dlsym(RTLD_DEFAULT, "swift_bridgeObjectRetain"))(object);
}
struct MetadataResponse { void *metadata; uintptr_t state; };
typedef struct MetadataResponse (*Metadata)(uintptr_t) __attribute__((swiftcall));
typedef struct MetadataResponse (*OptionalMetadata)(uintptr_t, void *) __attribute__((swiftcall));
typedef void (*InitKey)(void * __attribute__((swift_indirect_result)), uint16_t) __attribute__((swiftcall));
typedef void (*InitState)(void * __attribute__((swift_indirect_result)), uint8_t) __attribute__((swiftcall));
typedef void (*SendKey)(void *, void *, void *, void *, void * __attribute__((swift_context)), void ** __attribute__((swift_error_result))) __attribute__((swiftcall));
typedef void (*ReleaseError)(void *);

static void *keyMetadata, *stateMetadata, *optionalStateMetadata;
static InitKey initKey;
static InitState initState;
static SendKey sendKey;
static ReleaseError releaseError;

bool SSCoreDeviceKeyboardAvailable(void) {
    static dispatch_once_t once;
    static bool available;
    dispatch_once(&once, ^{
        if (!SSCoreDeviceInitialize()) return;
        bool found = true;
        Metadata keyType, stateType;
#define RESOLVE(variable, symbol) do { variable = (typeof(variable))SSCoreDeviceSymbol(symbol); found &= variable != NULL; } while (0)
        RESOLVE(keyType, "$s10CoreDevice20HIDKeyboardUsageCodeVMa");
        RESOLVE(stateType, "$s10CoreDevice14HIDButtonStateOMa");
        RESOLVE(initKey, "$s10CoreDevice20HIDKeyboardUsageCodeV8rawValueACs6UInt16V_tcfC");
        RESOLVE(initState, "$s10CoreDevice14HIDButtonStateO8rawValueACSgs5UInt8V_tcfC");
        RESOLVE(sendKey, "$s10CoreDevice11HIDKeyboardP4send3key5stateyAA0C9UsageCodeV_AA14HIDButtonStateOtKFTj");
#undef RESOLVE
        OptionalMetadata optionalType = (OptionalMetadata)dlsym(RTLD_DEFAULT, "$sSqMa");
        releaseError = (ReleaseError)dlsym(RTLD_DEFAULT, "swift_errorRelease");
        if (!found || !optionalType || !releaseError) return;
        keyMetadata = keyType(0).metadata;
        stateMetadata = stateType(0).metadata;
        if (!keyMetadata || !stateMetadata) return;
        optionalStateMetadata = optionalType(0, stateMetadata).metadata;
        // rawValue initializers construct Apple's resilient values. The state
        // initializer returns Optional, which may need an additional tag byte.
        available = optionalStateMetadata &&
            SSCoreDeviceValueSize(keyMetadata) == sizeof(uint16_t) &&
            SSCoreDeviceValueSize(stateMetadata) == sizeof(uint8_t) &&
            SSCoreDeviceValueSize(optionalStateMetadata) >= sizeof(uint8_t) &&
            SSCoreDeviceValueSize(optionalStateMetadata) <= 2;
    });
    return available;
}

bool SSCoreDeviceSendKey(void *capability, uint32_t usage, bool down) {
    if (!capability || usage > UINT16_MAX || !SSCoreDeviceKeyboardAvailable()) return false;
    void *metadata = ((void **)capability)[3], *witness = ((void **)capability)[4];
    if (!metadata || !witness) return false;

    uint8_t state[2] = {0};
    initState(state, down ? 1 : 2);
    if (!SSCoreDeviceOptionalHasValue(state, stateMetadata)) {
        SSCoreDeviceDestroyValue(state, optionalStateMetadata);
        return false;
    }
    uint16_t key = 0;
    initKey(&key, (uint16_t)usage);
    void *error = NULL;
    sendKey(&key, state, metadata, witness, capability, &error);
    SSCoreDeviceDestroyValue(&key, keyMetadata);
    SSCoreDeviceDestroyValue(state, optionalStateMetadata);
    // HIDKeyboard uses untyped Swift throws, unlike UniversalHID's typed
    // CoreDeviceError result. The error register owns a Swift error object.
    if (error) {
        releaseError(error);
        return false;
    }
    return true;
}

// Swift ABI value witnesses handle resilient values and Optional tags.
static void **valueWitnesses(void *metadata) {
    return ptrauth_strip(((void **)metadata)[-1], ptrauth_key_process_independent_data);
}
uintptr_t SSCoreDeviceValueSize(void *metadata) { return ((uintptr_t *)valueWitnesses(metadata))[8]; }
void SSCoreDeviceDestroyValue(void *value, void *metadata) {
    typedef void (*DestroyFn)(void *, void *) __attribute__((swiftcall));
    void *entry = ptrauth_strip(valueWitnesses(metadata)[1], ptrauth_key_function_pointer);
    DestroyFn destroy = ptrauth_sign_unauthenticated(entry, ptrauth_key_function_pointer, 0);
    destroy(value, metadata);
}
bool SSCoreDeviceOptionalHasValue(const void *value, void *wrappedMetadata) {
    typedef unsigned (*TagFn)(const void *, unsigned, void *) __attribute__((swiftcall));
    void *entry = ptrauth_strip(valueWitnesses(wrappedMetadata)[6], ptrauth_key_function_pointer);
    TagFn getTag = ptrauth_sign_unauthenticated(entry, ptrauth_key_function_pointer, 0);
    return getTag(value, 1, wrappedMetadata) == 0;
}
