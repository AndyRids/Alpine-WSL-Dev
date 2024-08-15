<#
Author: Andrew Ridyard
GitHub: https://github.com/AndyRids/Alpine-WSL-Dev
License: GNU General Public License v3.0

This script is used to watch the 'Microsoft-Windows-DeviceSetupManager/Admin' Windows Event log for
Raspberry Pi Pico device attachment events (ID 112) and attach them to any running WSL distributions,
using usbipd-win. WSL must be running for device attachment to take place and so, the script watches
for WSL startup events (System/Hyper-V-VmSwitch), in case a device is attached before starting WSL, \
prompting a follow-up attachment.

REQUIREMENTS: usbipd-win (https://github.com/dorssel/usbipd-win) & WSL installed

NOTE: For these events, we are looking for EventData DeviceName property containing values such as;
'Board in FS mode' (MicroPython), 'Pico' (Pico SDK) and 'RP2 Boot' (RP2040 Boot). An Administrator
PowerShell instance is needed to bind a device for the first time, to enable its attachment to WSL.

I usually run this script when I open Windows Terminal, inside an Administrator PowerShell instance,
before opening my Alpine Linux WSL instance - for MicroPython development on the RPi Pico and Pico W.
I use the Python library rshell to interface with my devices in MicroPython.

We can filter connected COM devices by Vendor ID and Product ID values, which are detailed below:

For a full list of Raspberry Pi vendor ID (VID) & product ID (PID) values,
see https://github.com/raspberrypi/usb-pid.

Raspberry Pi VID: 0x2E8A

Raspberry Pi PID:

┌────────┬──────────────────────────────────────────────┐
│   PID  │                    Product                   │
├────────┼──────────────────────────────────────────────┤
│ 0x0003 │ Raspberry Pi Pico W                          │
├────────┼──────────────────────────────────────────────┤
│ 0x0004 │ Raspberry Pi PicoProbe                       │
├────────┼──────────────────────────────────────────────┤
│ 0x0005 │ Raspberry Pi Pico MicroPython firmware (CDC) │
├────────┼──────────────────────────────────────────────┤
│ 0x000A │ Raspberry Pi Pico SDK CDC UART               │
├────────┼──────────────────────────────────────────────┤
│ 0x000B │ Raspberry Pi Pico CircuitPython firmware     │
├────────┼──────────────────────────────────────────────┤
│ 0x1000 │ Cytron Maker Pi RP2040                       │
└────────┴──────────────────────────────────────────────┘
#>

#requires -RunAsAdministrator
#requires -version 5.1

using namespace System.Diagnostics.Eventing
using namespace System.Management.Automation

# import usbipd-win PowerShell module
Import-Module $env:ProgramW6432'\usbipd-win\PowerShell\Usbipd.Powershell.dll'

# Used to represent all WSL distribution status values
enum WSLStatus {
    Stopped
    Running
    Installing
    Uninstalling
    Converting
}

<#
Used as a switch value relating to actions for binding and attaching COM
devices' data bus to active WSL distributions. Enum values are based on
the addition of IsBound & IsAttached Boolean properties of the objects
returned by Get-UsbipdDevice (usbipd-win).

A device can be:

1. Not shared or attached
2. Shared & not attached
3. Shared & attached
#>
enum COMStatus {
    NotShared
    Shared
    Attached
}


# Pico PID enumerations
enum PicoPID {
    RP2040Boot = 0x0003
    MicroPython = 0x0005
    PicoSDK = 0x000A
    CircuitPython = 0x000B
}


function global:Get-WSLDistributionInformation {
    <#
    .SYNOPSIS
        Get all WSL distribution details.

    .DESCRIPTION
        Parses the string output from wsl --list --verbose command
        into a hashtable with the following structure:

        [string]Name: distribution name
        [bool]Default: default distribution flag
        [string]Status: distribution status
        [int]Version: WSL version

    .INPUTS
        None

    .OUTPUTS
        System.hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        # [ValidateSetAttribute("Stopped", "Running", "Installing", "Uninstalling", "Converting")]
        [string[]]$Filter = [WSLStatus].GetEnumNames()
    )

    process {
        # Available WSL distributions & status
        $WSLOutput = wsl --list --verbose |
            Select-Object -Skip 1 -Unique |
            Where-Object -Property Length -gt 1

        $WSLOutput | ForEach-Object {
            <#
            An '*' before a distribution name would denote that
            particular WSL distribution as the WSL default.

            $WSLOutput:
                * Alpine    Stopped      2

            [Regex]::new("\b[^\w]{2,}").Replace($WSLOutput, "-"):
                * Alpine-Stopped-2

            ConvertFrom-String -Delimiter "-":
                P1: "* Alpine", P2: "Stopped", P3: "2"

            Select-Object:
                Name: Alpine, Default: True, Status: Stopped, Version: 2
            #>

            # Calculated properties for each WSL distribution object
            $Name = @{label="Name"; expression={$_.P1 -replace "[\*\s]", ""}}
            $Default = @{label="Default"; expression={$_.P1.StartsWith("*")}}
            $Status = @{label="Status"; expression={$_.P2}}
            $Version = @{label="Version"; expression={$_.P3}}

            # WSL distribution objects converted from distribution details string
            [Regex]::new("\b[^\w]{2,}").Replace($_.Trim(), "-") |
                ConvertFrom-String -Delimiter "-" |
                Select-Object -Property $Name, $Default, $Status, $Version |
                Where-Object Status -In $Filter
        }
    }
}


function global:Get-ConnectedDevice {
    <#
    .SYNOPSIS
        Get details for connected Raspberry Pi devices.

    .DESCRIPTION
        Invoke the usbipd-win PowerShell function Get-UsbipdDevice,
        filtering on Raspberry Pi Vendor ID (2E8A) and the passed
        Pico Product ID values (PicoPID enum). 'VerboseDescription'
        & 'Status' properties are added to each output object:

        [string]Status - NotShared | Shared | Attached
        [string]VerboseDescription - Description, PID name & bus

    .INPUTS
        None

    .OUTPUTS
        Usbipd.Automation.Device

    .NOTES
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PicoPID[]]$PIDValues
    )

    process {
        $PIDRegex = ($PIDValues | ForEach-Object { "{0:x4}" -f[int]$_ }) -Join "|"
        Get-UsbipdDevice |
            Where-Object { $_.IsConnected -and $_.HardwareId -match "2e8a:($PIDRegex)" } |
            ForEach-Object {
                # Create calculated properties for future use
                $PIDName = [PicoPID][int]$_.HardwareId.Pid
                $verboseText = "$($_.Description) [$PIDName PID] on bus $($_.BusId)"
                $VerboseDescription = @{ l="VerboseDescription"; e={ $verboseText } }
                $Status = @{ l="Status"; e={ [COMStatus][int]$_.IsBound + $_.IsAttached } }
                # Add new calculated properties - VerboseDescription & Status
                $_ | Select-Object -Property *, $VerboseDescription, $Status
            }
    }
}


function global:Approve-COMDeviceMountToWSL {
    <#
    .SYNOPSIS
        Share connected device to allow WSL attachment.

    .DESCRIPTION
        Invoke the command usbipd bind --busid $BusId to share
        a connected device, allowing it to be attached to WSL.

    .INPUTS
        None

    .OUTPUTS
        System.Void

    .NOTES
    #>
    [CmdletBinding()]
    [OutputType([Void])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern("^[1-9]-([1-9]$|1[0-5])")]
        [string]$BusId
    )

    process {
        usbipd bind --busid $BusId
    }
}


function global:Mount-COMDeviceToWSL {
    <#
    .SYNOPSIS
        Attach connected device to WSL distributions if active.

    .DESCRIPTION
        Invoke the command usbipd --wsl --busid $busId to attach a
        connected device (if shared) to WSL distributions (if active).

    .INPUTS
        None

    .OUTPUTS
        System.Void

    .NOTES
        A connected device must be shared before it can be attached
        to WSL. The Approve-COMDeviceMountToWSL function can be used
        to share the device if administrator rights are active.

        Use the common parameter -InformationAction Continue to display
        verbose information regarding device attachment to WSL.
    #>
    [CmdletBinding()]
    [OutputType([Void])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern("^[1-9]-([1-9]$|1[0-5])")]
        [string]$BusId
    )

    process {
        $device = Get-ConnectedDevice -PIDValues $([PicoPID].getEnumNames()) |
            Where-Object { $_.BusId -eq $BusId -and $_.IsBound }

        if (-not $device) {
            Write-Information -MessageData "[Not shared] cannot attach device on bus $BusId"
            return $null
        }

        $deviceDescription = $device.VerboseDescription

        $isActiveWSL = (Get-WSLDistributionInformation -Filter Running).Count -gt 0

        if ($isActiveWSL) {
            Write-Information -MessageData "[Attach to WSL] WSL active - attaching $deviceDescription"
            usbipd attach --wsl --busid $busId | Write-Information
        } else {
            Write-Information -MessageData "[Attach to WSL] WSL inactive - not attaching $deviceDescription"
        }
        Out-Null
    }
}


function global:Connect-COMDeviceToWSL {
    <#
    .SYNOPSIS
        Facilitate device connection to active WSL distributions.

    .DESCRIPTION
        Invokes usbipd-win commands for binding and attaching a
        COM device's data bus to active WSL distributions based
        on the connected device status:

        1. Not shared (or attached)
        2. Shared (but not attached)
        3. Shared & attached

        NOTE: If there are active WSL distributions, then
        a device will be shared & attached.

    .INPUTS
        None.

    .OUTPUTS
        hashtable.
    #>
    [CmdletBinding()]
    [OutputType([System.Void])]
    param (
        [Parameter(Mandatory = $false)]
        [PicoPID[]]$PIDValues = @("RP2040Boot", "MicroPython", "PicoSDK", "CircuitPython")
    )

    process {
        $connectedDevices = Get-ConnectedDevice -PIDValues $PIDValues

        switch ($connectedDevices) {
            ({ $_.Status -eq "NotShared" }) {
                Approve-COMDeviceMountToWSL -BusId $_.BusId
                Mount-COMDeviceToWSL -BusId $_.BusId
                continue
            }
            ({ $_.Status -eq "Shared" }) {
                Mount-COMDeviceToWSL -BusId $_.BusId
                continue
            }
            ({ $_.Status -eq "Attached" }) {
                Write-Information "[WSL active] - $($_.VerboseDescription) already attached"
                continue
            }
            Default { Write-Information "[Not found] No devices with matching PID; $PIDValues"}
        }
    }
}

<#
Start a WSL distribution
-----------------------------------
Log Name: System
Source: Hyper-V-VmSwitch
Event ID: 232
-----------------------------------
NIC B944A522-3D6A-4950-A844-16DC623D891A--6B4A85CC-55A1-4C9F-8C85-44C2A33AAE4A (Friendly Name: )
successfully connected to port 6B4A85CC-55A1-4C9F-8C85-44C2A33AAE4A (Friendly Name: 6B4A85CC-55A1-4C9F-8C85-44C2A33AAE4A)
on switch 790E58B4-7939-4434-9358-89AE7DDBE87E(Friendly Name: WSL (Hyper-V firewall)).
-----------------------------------
EventData
  NicNameLen 74
  NicName B944A522-3D6A-4950-A844-16DC623D891A--6B4A85CC-55A1-4C9F-8C85-44C2A33AAE4A
  NicFNameLen 0
  NicFName
  PortNameLen 36
  PortName 6B4A85CC-55A1-4C9F-8C85-44C2A33AAE4A
  PortFNameLen 36
  PortFName 6B4A85CC-55A1-4C9F-8C85-44C2A33AAE4A
  SwitchNameLen 36
  SwitchName 790E58B4-7939-4434-9358-89AE7DDBE87E
  SwitchFNameLen 22
  SwitchFName WSL (Hyper-V firewall)
#>

# Query options & filter
$SystemLog = "System"
$HyperVFilter = "*[System[(EventID=232)] and EventData[(Data='WSL (Hyper-V firewall)')]]"
$HyperVQuery = [Reader.EventLogQuery]::new($SystemLog, [Reader.PathType]::LogName, $HyperVFilter)

# Overload used: EventLogWatcher(EventLogQuery, EventBookmark, Boolean)
# Boolean determines inclusion of pre-existing events that match the EventLogQuery
$HyperVWatcher = [Reader.EventLogWatcher]::new($HyperVQuery, $null, $false)
$HyperVWatcher.Enabled = $true

<#
Attach Raspberry Pi Pico
-----------------------------------
Log Name: Microsoft-Windows-DeviceSetupManager/Admin
Log path: %SystemRoot%\System32\Winevt\Logs\Microsoft-Windows-DeviceSetupManager%4Admin.evtx
Event ID: 112
-----------------------------------
Device 'Board in FS mode' ({8d7d90ed-ac33-50a0-b7d8-4b3d1f750bd7}) has been serviced, processed 4 tasks,
wrote 0 properties, active worktime was 145 milliseconds.
-----------------------------------
EventData
  Prop_DeviceName 'Board in FS mode', 'Pico', 'RP2 Boot'
  Prop_ContainerId {8d7d90ed-ac33-50a0-b7d8-4b3d1f750bd7}
  Prop_TaskCount 4
  Prop_PropertyCount 0
  Prop_WorkTime_MilliSeconds 145
#>

# Query options & filter
$DeviceSetupManagerLog = "Microsoft-Windows-DeviceSetupManager/Admin"
$FSModeFilter = "*[System[(EventID=112)] and EventData[Data='Board in FS mode' or Data='Pico' or Data='RP2 Boot']]"
$DeviceQuery = [Reader.EventLogQuery]::new($DeviceSetupManagerLog, [Reader.PathType]::LogName, $FSModeFilter)

# Overload used: EventLogWatcher(EventLogQuery, EventBookmark, Boolean)
# Boolean determines inclusion of pre-existing events that match the EventLogQuery
$DeviceWatcher = [Reader.EventLogWatcher]::new($DeviceQuery, $null, $false)
$DeviceWatcher.Enabled = $true


$Action = {
    <#
    NOTE: The commands in the Action run when an event is raised, instead of sending the
    event to the event queue, making the 'Wait-Event' (Ln 285) act as an indefinite wait.

    This script has access to automatic variables;

    $Event, $EventSubscriber, $Sender, $EventArgs & $Args.
    #>

    # $EventArgs.EventRecord.Properties | Get-Member -MemberType Property | Out-Host
    # $EventArgs.EventRecord.Properties | Select-Object | Out-Host

    $PIDValues = [PicoPID].GetEnumNames()
    $availableDevices = Get-ConnectedDevice -PIDValues $PIDValues | Where-Object Status -NE "Attached"

    <#
    When usbipd-win attaches a device, it creates a another event, which matches the 112 ID events
    we are watching for, in the 'Microsoft-Windows-DeviceSetupManager/Admin' events log.

    TODO: Implement logic to ignore these duplicate events, possibly by temporarily watching the Application log
    for Event ID 1 from 'usbipd-win' source detailing an event with a 'Usbipd.ConnectedClient' event category and
    switching of the event watcher until this 'usbipd-win' event has passed.

    As a temporary solution, I check for any devices, which are not already attached and are therefore either not shared 
    or shared and therefore available for attachment to WSL (if running). If this was a duplicate event, then the device will
    already be attached.

    NOTE: Technically, Connect-COMDeviceToWSL handles devices that are already attached and does not attempt to attach them.
    #>

    if ($availableDevices) {
        $recordProperties = $EventArgs.EventRecord.Properties
        $identifierMap = @{
            DeviceConnection = $recordProperties | Select-Object -First 1 -Property Value -ExpandProperty Value
            HyperVConnection = $recordProperties | Select-Object -Last 1 -Property Value -ExpandProperty Value
        }

        $sourceIdentifier = $Event.SourceIdentifier

        $informationParams = @{
            MessageData = "`n[Event detected - $($identifierMap[$SourceIdentifier])]"
            Tags = $sourceIdentifier
            InformationAction = [ActionPreference]::Continue
        }
        Write-Information @informationParams

        Connect-COMDeviceToWSL -InformationAction Continue
    }
}

$HyperVEventParams = @{
    InputObject = $HyperVWatcher
    EventName = "EventRecordWritten"
    SourceIdentifier = "HyperVConnection"
    Action =  $Action
}

$DeviceEventParams = @{
    InputObject = $DeviceWatcher
    EventName = "EventRecordWritten"
    SourceIdentifier = "DeviceConnection"
    Action =  $Action
}

$JobDevice = Register-ObjectEvent @DeviceEventParams
$JobHyperV = Register-ObjectEvent @HyperVEventParams

try {
    $informationParams = @{
        MessageData = "`nWatching for device connections`n"
        InformationAction = [ActionPreference]::Continue
    }
    Write-Information @informationParams

    <#
    Indefinite wait for 'DeviceConnection' & 'HyperVConnection' events, as they are handled by
    the $Action script. Wait-Event call prevents the script from exiting, without blocking.
    NOTE: Use Ctrl-C to exit the script
    #>
    Wait-Event
}
catch {
    Write-Error $_
}
finally {
    Write-Warning "Script terminated - WSL & RPi device connection monitoring stopped."

    # Unregister events for each EventSubscriber
    Get-EventSubscriber -SourceIdentifier "DeviceConnection" | Unregister-Event
    Get-EventSubscriber -SourceIdentifier "HyperVConnection" | Unregister-Event

    # Delete the background JobDevice & JobHyperV background jobs
    $JobDevice | Remove-Job -Force
    $JobHyperV | Remove-Job -Force
}
