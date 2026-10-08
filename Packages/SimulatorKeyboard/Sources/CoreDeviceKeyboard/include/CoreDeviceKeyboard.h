#pragma once
#include <stdbool.h>
#include <stdint.h>
bool SSCoreDeviceInitialize(void);
void *SSCoreDeviceSymbol(const char *name);
void SSCoreDeviceRetainBridgeObject(void *object);
uintptr_t SSCoreDeviceValueSize(void *metadata);
void SSCoreDeviceDestroyValue(void *value, void *metadata);
bool SSCoreDeviceOptionalHasValue(const void *value, void *wrappedMetadata);
bool SSCoreDeviceKeyboardAvailable(void);
bool SSCoreDeviceSendKey(void *capability, uint32_t usage, bool down);
