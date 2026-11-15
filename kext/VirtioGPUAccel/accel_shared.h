// Shared between VirtioGPUAccel.cpp (the accelerator, display pipe) and VGDeviceControl.cpp (AGDC).
#pragma once
#include <IOKit/IOService.h>

// A line for the accelerator's log ("VirtioGPUAccelLog" on the PCI device and the core's ProbeLog).
void vgaccel_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// Creates, attaches and starts the AppleGraphicsDeviceControl on the PCI device; returns it retained, or null.
IOService *vgaccel_agdc_create(IOService *pci, IOService *fb);
