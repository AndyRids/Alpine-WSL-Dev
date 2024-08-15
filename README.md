# Alpine-WSL-Dev

This repository contains instructions and scripts used to install and setup an Alpine Linux minimal root filesystem on WSL2.

[Alpine Linux](https://alpinelinux.org/about/) is an independent, non-commercial, general purpose Linux distribution. Alpine Linux is built around musl libc and BusyBox. This makes it small and very resource efficient. A container requires no more than 8 MB and a minimal installation to disk requires around 130 MB of storage.

## Introduction

This setup is used mainly for Python development on WSL, but is also used for front-end projects and embedded projects using MicroPython and C on Raspberry Pi devices, which must be attached to WSL using [usbipd-win](https://github.com/dorssel/usbipd-win).

OpenRC is the init system used in alpine. The init system manages the services, such as mdev, which is the default device manager on Alpine Linux. It is provided by busybox as alternative to systemd's udev. This setup allows mdev to act as a hotplug manager and facilitates access to USB and COM devices when attached to WSL distributions, by dynamically updating `/dev` based on your mdev config rules.

I prefer to use [Windows Terminal](https://apps.microsoft.com/detail/9n0dx20hk701?hl=en-US&gl=US) to manage my profiles for PowerShell and WSL distributions.

<!-- [!TIP] [!IMPORTANT] [!WARNING] [!CAUTION] -->

> [!NOTE]
> mdev is not recommended for a full blown desktop environment, but it is perfect for a minimal WSL install.


## 1. Download & install Alpine Linux

The minimal root filesystem can be downloaded from [Alpine Linux Downloads](https://alpinelinux.org/downloads/). I create a WSL directory and a subdirectory for each distribution (e.g. `C:\WSL\Alpine`), where I keep my distribution images and where I have WSL create the vhdx image files. 

On an administrator PowerShell, Alpine can be installed using the following commands:

```ps
wsl --import Alpine C:\WSL\Alpine C:\WSL\Alpine\alpine-minirootfs-3.20.1-x86_64.tar
```
Check installation by listing distributions with verbose output:

```ps
wsl -l -v
```

## 2. Setup Alpine Linux

I use a profile within Windows Terminal (Microsoft Store), which is set to run Alpine with the following command `C:\windows\system32\wsl.exe -d Alpine`. See here [Alpine Linux post-install guide](https://docs.alpinelinux.org/user-handbook/0.1a/Working/post-install.html) for a useful post-install guide.

### New user setup

New user setup - replace <username> with your username:

```sh
adduser -h /home/username -s /bin/ash username
su -l root
```

This setup uses doas rather than sudo and is more minimal:

```sh
apk update && apk upgrade
apk add doas
```

Add the new user to the wheel group:

```sh
echo 'permit :wheel' > /etc/doas.d/doas.conf
adduser username wheel
```
 
Microcontrollers attached to WSL are often placed in the dialout group by mdev rules (/dev/ttyACM[0-9]). The command below
adds the user to the dialout group to facilitate connecting to these devices (if needed):

```sh
adduser username dialout
```

In Alpine, the doas.conf file is at the path `/etc/doas.d/`:

```sh
su -l username
doas vi /etc/doas.d/doas.conf
```

Below is an example for `/etc/doas.d/doas.conf` settings, which allow a user to perform
apk update and apk upgrade as root without a password:

```sh
# permit apk update & apk upgrade without password for user <username>
permit nopass username as root cmd apk args update
permit nopass username as root cmd apk args upgrade
```

Test doas config settings:

```sh
doas apk update && doas apk upgrade
```

### OpenRC, mdev & hwdrivers setup

Below details installation & setup of OpenRC with mdev and hwdrivers on WSL2. mdev and OpenRC can be installed using apk:

```sh
doas apk add busybox-mdev-openrc
```

Enable mdev & hwdrivers services at the sysinit runlevel:

```sh
doas rc-update add mdev sysinit
doas rc-update add hwdrivers sysinit
```
Check sysinit runlevel services:

```sh
rc-status sysinit
```

Start mdev & hwdrivers, if currently stopped:

```sh
doas rc-service mdev --ifstopped start
doas rc-service hwdrivers --ifstopped start
```

Manually seed `/dev` with device nodes based on current mdev config file:

```sh
doas mdev -s
```
View changes:

```sh
ls -la /dev
```

Below is my init file for mdev at `/etc/init.d/mdev`, which I modified to run mdev as a daemon, which allowed me to
have mdev run as a hotplug manager similar to udev. Whenever I plug in a Raspberry Pi device and share and attach it 
to WSL, I want mdev to respond to a uevent and parse the `/etc/mdev.conf` looking for matching rules for the attached 
device, which is usually ttyACM[0-9]. The modified line is `mdev -d` in the `_start_service` function, which replaced
`mdev -s`.

```sh
#!/sbin/openrc-run

description="the mdev device manager"

depend() {
        provide dev
        need sysfs dev-mount
        before checkfs fsck
        keyword -containers -vserver -lxc
}

_start_service () {
        ebegin "Starting busybox mdev"
        mkdir -p /dev
        echo >/dev/mdev.seq
        echo "/sbin/mdev" > /proc/sys/kernel/hotplug
        eend $?
}

_start_coldplug () {
        ebegin "Scanning hardware for mdev"
        # mdev -s will not create /dev/usb[1-9] devices with recent kernels
        # so we manually trigger events for usb
        for i in $(find /sys/devices -name 'usb[0-9]*'); do
                [ -e $i/uevent ] && echo add > $i/uevent
        done
        # trigger the rest of the coldplug
        # mdev -s is replaced with mdev -d to have it run as a daemon
        mdev -d
        eend $?
}

start() {
        _start_service
        _start_coldplug
}

stop() {
        ebegin "Stopping busybox mdev"
        echo > /proc/sys/kernel/hotplug
        eend
}
```

Below is the mdev rule in the `/etc/mdev.conf` file which is relevant to RPi Microcontrollers and probably Arduino devices:

```sh
ttyACM[0-9]     root:dialout 0660 @ln -sf $MDEV modem
```

Here is the full `/etc/mdev.conf` file and corresponding rules:

```sh
#
# This is a sample mdev.conf.
#

# Devices:
# Syntax: %s %d:%d %s
# devices user:group mode

$MODALIAS=.*    root:root       0660    @modprobe -q -b "$MODALIAS"

# null does already exist; therefore ownership has to be changed with command
null    root:root 0666  @chmod 666 $MDEV
zero    root:root 0666
full    root:root 0666

random  root:root 0666
urandom root:root 0444
hwrandom root:root 0660

console root:tty 0600

# load frambuffer console when first frambuffer is found
fb0     root:video 0660 @modprobe -q -b fbcon

fd0     root:floppy 0660
kmem    root:kmem 0640
mem     root:kmem 0640
port    root:kmem 0640
ptmx    root:tty 0666

# Kernel-based Virtual Machine.
kvm             root:kvm 660

# ram.*
ram([0-9]*)     root:disk 0660 >rd/%1
loop([0-9]+)    root:disk 0660 >loop/%1

# persistent storage
dasd.*          root:disk 0660 */lib/mdev/persistent-storage
mmcblk.*        root:disk 0660 */lib/mdev/persistent-storage
nbd.*           root:disk 0660 */lib/mdev/persistent-storage
nvme.*          root:disk 0660 */lib/mdev/persistent-storage
sd[a-z].*       root:disk 0660 */lib/mdev/persistent-storage
sr[0-9]+        root:cdrom 0660 */lib/mdev/persistent-storage
vd[a-z].*       root:disk 0660 */lib/mdev/persistent-storage
xvd[a-z].*      root:disk 0660 */lib/mdev/persistent-storage

md[0-9]         root:disk 0660

tty             root:tty 0666
tty[0-9]        root:root 0600
tty[0-9][0-9]   root:tty 0660
ttyS[0-9]*      root:dialout 0660
ttyGS[0-9]      root:root 0660
pty.*           root:tty 0660
vcs[0-9]*       root:tty 0660
vcsa[0-9]*      root:tty 0660

# rpi bluetooth
#ttyAMA0        root:tty 660 @btattach -B /dev/$MDEV -P bcm -S 115200 -N &

ttyACM[0-9]     root:dialout 0660 @ln -sf $MDEV modem
ttyUSB[0-9]     root:dialout 0660 @ln -sf $MDEV modem
ttyLTM[0-9]     root:dialout 0660 @ln -sf $MDEV modem
ttySHSF[0-9]    root:dialout 0660 @ln -sf $MDEV modem
slamr           root:dialout 0660 @ln -sf $MDEV slamr0
slusb           root:dialout 0660 @ln -sf $MDEV slusb0
fuse            root:root  0666

# mobile broadband modems
cdc-wdm[0-9]+   root:dialout 0660

# dri device
dri/.*          root:video 0660
card[0-9]       root:video 0660 =dri/

# alsa sound devices and audio stuff
pcm.*           root:audio 0660 =snd/
control.*       root:audio 0660 =snd/
midi.*          root:audio 0660 =snd/
seq             root:audio 0660 =snd/
timer           root:audio 0660 =snd/

adsp            root:audio 0660 >sound/
audio           root:audio 0660 >sound/
dsp             root:audio 0660 >sound/
mixer           root:audio 0660 >sound/
sequencer.*     root:audio 0660 >sound/

SUBSYSTEM=sound;.*      root:audio 0660

# PTP devices
ptp[0-9]        root:root 0660 */lib/mdev/ptpdev

# virtio-ports
SUBSYSTEM=virtio-ports;vport.* root:root 0600 @mkdir -p virtio-ports; ln -sf ../$MDEV virtio-ports/$(cat /sys/class/virtio-ports/$MDEV/name)

# misc stuff
agpgart         root:root 0660  >misc/
psaux           root:root 0660  >misc/
rtc             root:root 0664  >misc/

# input stuff
SUBSYSTEM=input;.*  root:input 0660

# v4l stuff
vbi[0-9]        root:video 0660 >v4l/
video[0-9]+     root:video 0660 >v4l/

# dvb stuff
dvb.*           root:video 0660 */lib/mdev/dvbdev

# VideoCore VC4 BCM GPU specific (as in Pi devices)
vchiq   root:video 0660
vcio    root:video 0660
vcsm-cma        root:video 0660
vc-mem  root:video 0660

# load drivers for usb devices
usb[0-9]+       root:root 0660 */lib/mdev/usbdev

# net devices
# 666 is fine: https://www.kernel.org/doc/Documentation/networking/tuntap.txt
net/tun[0-9]*   root:netdev 0666
net/tap[0-9]*   root:netdev 0666

# zaptel devices
zap(.*)         root:dialout 0660 =zap/%1
dahdi!(.*)      root:dialout 0660 =dahdi/%1
dahdi/(.*)      root:dialout 0660 =dahdi/%1

# raid controllers
cciss!(.*)      root:disk 0660 =cciss/%1
cciss/(.*)      root:disk 0660 =cciss/%1
ida!(.*)        root:disk 0660 =ida/%1
ida/(.*)        root:disk 0660 =ida/%1
rd!(.*)         root:disk 0660 =rd/%1
rd/(.*)         root:disk 0660 =rd/%1

# tape devices
nst[0-9]+.*     root:tape 0660
st[0-9]+.*      root:tape 0660

# VirtualBox devices
vboxguest   root:root 0600
vboxuser    root:root 0666
vboxdrv     root:root 0600
vboxdrvu    root:root 0666
vboxnetctl  root:root 0600

# fallback for any!device -> any/device
(.*)!(.*)       root:root 0660 =%1/%2
```

### WSL configuration file

I configure WSL with the following config file at `/etc/wsl.conf`. I set the default WSL username under the `[user]` 
settings and facilitate openrc starting with WSL, by using the command `command = "/sbin/openrc default"` under `[boot]`. 
The `appendWindowsPath = true` setting under `[interop]`, allows the addition of Windows tools to be added to the WSL distro 
`$PATH` automatically. The command `code .` would for example, be available in WSL and launch VSCode in the current working WSL 
directory.

```sh
# /etc/wsl.conf
[automount]
enabled = true
mountFsTab = true

[network]
generateHosts = true
generateResolvConf = true

[interop]
enabled = true
appendWindowsPath = true

[user]
default = username

[boot]
command = "/sbin/openrc default"
```

### Profile configuration

When we imported this distro of Alpine Linux manually, the `/etc/profile` file overwrites the `$PATH` environment variable and therefore 
overwrites the directories added by Windows from the aforementioned `appendWindowsPath = true` setting. I correct this by editing the 
`/etc/profile` file. You could also add anything else to the path here such as `export PATH="$PATH:/home/username/projects/.venv-poetry/bin"`,
which in my case, would add my Poetry package manager to the PATH.


```sh
# replace the existing PATH declaration:
export PATH="$PATH"

export PAGER=less
umask 022

# use nicer PS1 for bash and busybox ash
if [ -n "$BASH_VERSION" -o "$BB_ASH_VERSION" ]; then
        PS1='\h:\w\$ '
# use nicer PS1 for zsh
elif [ -n "$ZSH_VERSION" ]; then
        PS1='%m:%~%# '
# set up fallback default PS1
else
        : "${HOSTNAME:=$(hostname)}"
        PS1='${HOSTNAME%%.*}:$PWD'
        [ "$(id -u)" -eq 0 ] && PS1="${PS1}# " || PS1="${PS1}\$ "
fi

for script in /etc/profile.d/*.sh ; do
        if [ -r "$script" ] ; then
                . "$script"
        fi
done
unset script
```
### Restart WSL 

I reboot and restart Alpine linux to let the new configs take effect.

With the below command, you should see mdev & hwdrivers under syinit runlevel:

```sh
rc-update show -v
```

Check mdev and hwdrivers services are started:

```sh
# should see * status: started for both services
rc-service mdev status && rc-service hwdrivers status
```

## 3. Setup USB Device Sharing to WSL2 (Microcontrollers)

I use usbipd-win to share locally connected USB devices to other machines, including Hyper-V guests and WSL 2.
By default devices are not shared with USBIP clients. To lookup and share devices, run the following commands with 
administrator privileges:

Install usbipd-win with winget:
```ps1
winget install usbipd
```

List devices with busid & state information using `usbipd list` command:

```ps1
usbipd list
```

The below image shows a connected Raspberry Pi Pico W device (highlighted in blue), with MicroPython installed. Raspberry Pi Vendor ID (VID) is '0x2e8a' and the
Product ID (PID) for MicroPython is '0x0005'. The device has been 'Shared' using the command `usbipd bind --busid 1-7`. All devices must be shared before they can be attached.

![usbipd list example](images/usbipd-list.png)

To share your device run the following command with the relevant busid value seen in the `usbipd list` output:

```ps1
usbipd bind --busid 1-7
```
![usbipd list example](images/usbipd-bind.png)

As long as WSL is running, you can then attach the device to WSL using the following command:

```ps1
usbipd attach --wsl --busid 1-7
```
![usbipd list example](images/usbipd-attach.png)


In Alpine Linux you can test the device is attached using the `lsusb` command and by checking that the mdev hotplug settings have been
utilised with the following command:

```sh
ls -la /dev/ttyACM*
```
The below image shows the command result before and after attachment:

![usbipd list example](images/alpine-ls-dev.png)

## 4. Powershell Script to Automate Device Sharing to WSL2

The `Watch-PicoConnect.ps1` script can be used to automate Pico attachment to WSL on connection. I run this script in an Administrator PowerShell instance using the following command:

```ps1
. .\Watch-PicoConnect.ps1
```
![usbipd list example](images/pico-connect-script.png)

> [!WARNING]
> This script is still in development and might need tweaking for your requirements.