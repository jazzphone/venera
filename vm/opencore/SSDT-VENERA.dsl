/*
 * SSDT-VENERA: what macOS wants from a QEMU q35 VM's ACPI and doesn't find there.
 *   EC    an embedded controller device (macOS looks for one; it does nothing here), Darwin only
 *   USBX  the USB power properties a Mac's ports have
 *   C000  the first CPU's plugin-type 1 (XCPM power management), on QEMU's \_SB.CPUS.C000
 * Venera's own (vm/opencore), compiled by build.sh with iasl.
 */
DefinitionBlock ("", "SSDT", 2, "VENERA", "VmFixups", 0x00001000)
{
    External (_SB_.PCI0, DeviceObj)
    External (_SB_.CPUS.C000, ProcessorObj)

    Scope (\_SB.PCI0)
    {
        Device (EC)
        {
            Name (_HID, "ACID0001")
            Method (_STA, 0, NotSerialized)
            {
                If (_OSI ("Darwin"))
                {
                    Return (0x0F)
                }
                Return (Zero)
            }
        }
    }

    Scope (\_SB)
    {
        Device (USBX)
        {
            Name (_ADR, Zero)
            Method (_STA, 0, NotSerialized)
            {
                If (_OSI ("Darwin"))
                {
                    Return (0x0F)
                }
                Return (Zero)
            }
            Method (_DSM, 4, NotSerialized)
            {
                If ((Arg2 == Zero))
                {
                    Return (Buffer (One) { 0x03 })
                }
                Return (Package (0x08)
                {
                    "kUSBSleepPowerSupply", 0x13EC,
                    "kUSBSleepPortCurrentLimit", 0x0834,
                    "kUSBWakePowerSupply", 0x13EC,
                    "kUSBWakePortCurrentLimit", 0x0834
                })
            }
        }
    }

    If (CondRefOf (\_SB.CPUS.C000))
    {
        Scope (\_SB.CPUS.C000)
        {
            Method (_DSM, 4, NotSerialized)
            {
                If (!_OSI ("Darwin"))
                {
                    Return (Buffer (One) { Zero })
                }
                If ((Arg2 == Zero))
                {
                    Return (Buffer (One) { 0x03 })
                }
                Return (Package (0x02)
                {
                    "plugin-type", One
                })
            }
        }
    }
}
