# Control4 CORE-1 hardware

What we know about the controller DirectorLink runs on, from two sources:

- Control4's **CORE 1 Dealer Installation Guide** (document 200-00724, rev B) for the official specifications.
- A **read-only inspection** of a working CORE-1 in a home (Control4 OS 3.4.3, September 2026) over SSH. Nothing was changed on it; the commands are listed at the end so the same checks can be repeated on other controllers.

Serial numbers, MAC addresses and network addresses are left out on purpose.

## At a glance

| | |
| --- | --- |
| Model | Control4 CORE 1 (device tree: `Control4 i.MX8MQ Core1`, board codename *loki*, board revision 1.9) |
| Processor | NXP i.MX 8M Quad: 4 × Arm Cortex-A53 (1.0 / 1.5 GHz) + 1 × Arm Cortex-M4 co-processor |
| Memory | 2 GB DDR (1.94 GiB visible; 960 MB reserved for graphics and video) |
| Storage | 32 GB eMMC (SanDisk) |
| Network | 2 × Gigabit Ethernet through a built-in 2-port switch; the IN port takes PoE+ |
| Radio | Zigbee Pro (802.15.4), external antenna; no Wi-Fi or Bluetooth built in |
| Video / audio | HDMI 2.0a (4K 60 Hz, HDCP 2.2); HDMI audio and coaxial S/PDIF |
| Control ports | 4 IR outputs (ports 1–2 double as RS-232), 1 IR receiver on the front |
| Other | 1 × USB 2.0 port, ID button, reset pinhole, 4 front LEDs |
| Power | 100–240 V AC or PoE+; 9 W idle, 18 W maximum |
| Operating system | Control4 OS 3.4 (Yocto *Honister*), Linux 5.15, 64-bit |

## Official specifications

From the installation guide.

| Item | Specification |
| --- | --- |
| Video out | 1 × HDMI 2.0a, 3840 × 2160 @ 60 Hz, HDCP 2.2 and 1.4 |
| Audio out | HDMI and 1 × digital coax |
| Audio formats | AAC, AIFF, ALAC, FLAC, M4A, MP2, MP3, MP4, Ogg Vorbis, PCM, WAV, WMA; up to 192 kHz / 24 bit |
| Ethernet | 2 × 10/100/1000BaseT: **ENET/PoE+ IN** and **ENET OUT** (acts as a 2-port switch) |
| Wi-Fi | Optional dual-band USB adapter (C4-USBWIFI) |
| Zigbee | Zigbee Pro 802.15.4, external reverse-SMA antenna |
| USB | 1 × USB 2.0, 500 mA (turned off on over-current) |
| IR out | 4 × 3.5 mm, 5 V 27 mA max |
| IR capture | 1 receiver on the front, 20–60 kHz |
| Serial | 2 × RS-232 on IR ports 1 and 2 (3.5 mm to DB9 cable), 1200–115200 baud, no hardware flow control, straight-through or null-modem set in Composer |
| Power | 100–240 V AC 50/60 Hz (IEC 60320-C5 cord) or PoE+ |
| Consumption | Idle 9 W (30 BTU/h), maximum 18 W (61 BTU/h) |
| Operating temperature | 0–40 °C (32–104 °F) |
| Storage temperature | −20–70 °C (−4–158 °F) |
| Size (H × W × D) | 29.5 × 195 × 132 mm (1.16 × 7.67 × 5.2 in) |
| Weight | 0.68 kg (1.5 lb); shipping 1.04 kg |
| Mounting | Rubber feet; optional wall bracket (C4-CORE1-WM) or 1U rack kit (C4-CORE1-RMK) |

**Front:** Activity LED (audio streaming), IR window, Caution LED (solid red, then blinking blue while booting; blinking orange during a factory restore), Link LED (identified in a project and talking to Director), Power LED (blue).
**Back:** power, IR OUT / SERIAL 1–4, USB, DIGITAL AUDIO, HDMI OUT, ID button (also an LED) and RESET pinhole, ENET OUT, ENET/PoE+ IN, ZIGBEE antenna.

## Processor, memory and storage

- **CPU:** 4 × Cortex-A53 (Arm part `0xd03`, r0p4) with the Armv8 crypto extensions (`aes`, `pmull`, `sha1`, `sha2`, `crc32`), so TLS is hardware-assisted. Frequency scaling between 1.0 and 1.5 GHz (`ondemand` governor).
- **Co-processor:** a Cortex-M4 runs Control4's firmware `/lib/firmware/m4.bin`, loaded by U-Boot at boot (not by Linux `remoteproc`). Linux talks to it over RPMsg; see *Ports* below.
- **Graphics and video:** the i.MX 8M Quad's GPU and video units drive the HDMI output (DRM `card0` with `HDMI-A-1`, render node `renderD128`). 960 MB of memory is set aside for them (CMA).
- **Memory:** 1.94 GiB total, about 0.8 GiB available during normal operation, plus 2 GiB of compressed swap in RAM (zram, not on the eMMC).
- **eMMC:** SanDisk (manufacturer id 0x45, product `DA6032`), 29.1 GiB, three partitions:

| Partition | Size | Use |
| --- | --- | --- |
| `mmcblk0p1` | 128 MB, FAT | `/boot`: kernel `Image`, about 30 device trees (`c4-imx8mq-*.dtb`), boot scripts |
| `mmcblk0p2` | 1.5 GB | `recovery`: the factory-restore system |
| `mmcblk0p3` | 27.5 GB, ext4 | `/` (read-write), about 4.9 GB used; Director and the drivers live in `/control4` (about 180 MB) |

## Components on the board

Found on the I²C and SPI buses:

| Bus / address | Part | Role |
| --- | --- | --- |
| I²C 0 · 0x4b | ROHM BD71837 | Power management (PMIC) for the i.MX 8M |
| I²C 1 · 0x40 | TI TLC59108 | LED driver for the front LEDs |
| I²C 1 · 0x48 | TI TMP75C | Board temperature sensor |
| I²C 1 · 0x51 | NXP PCF85363 | Real-time clock |
| I²C 2 · 0x38 | Analog Devices ADAU1466 (`adau1466-thor`) | Audio DSP listed in the device tree, but no sound card uses it — probably not fitted on CORE-1, which has no analog audio out |
| SPI 0 | Silicon Labs EFR32 | Zigbee radio (`spidev0.0`, with reset/boot control lines) |
| MDIO / DSA | MaxLinear GSW120 | 2-port Gigabit switch behind the SoC's Ethernet |

## Ports as the operating system sees them

| Port | Linux | Used by |
| --- | --- | --- |
| ENET/PoE+ IN, ENET OUT | switch ports `lan1`, `lan2` (driver `mxl-gsw1xx`) on the SoC Ethernet `fec1`, bridged into one interface `eth0` | Director and everything on the network |
| SERIAL 1, SERIAL 2 | `ttymxc1`, `ttymxc2` (i.MX UARTs 2 and 3) | `ioserver` |
| IR out 1–4, IR receiver | through the Cortex-M4: RPMsg channel `ttyRPMSG80` | `ioserver` |
| Other M4 channels | `ttyRPMSG30`, `ttyRPMSG40` | — |
| Internal console | `ttymxc0` (i.MX UART 1), 115200 baud, login prompt | — (no external connector) |
| HDMI | DRM `card0`, ALSA card `imx-hdmi` | the on-screen navigator and audio |
| DIGITAL AUDIO (coax) | ALSA card `imx-spdif` | Control4 audio services (`audio3server`, `audio3streamer`, `audio3clock`) |
| USB | 2 × xHCI host controllers; 1 port on the back | external storage, the optional Wi-Fi adapter |
| Zigbee | `spidev0.0` | Control4's Zigbee server (not running here: the project has no Zigbee devices) |
| LEDs | TLC59108 | `led_service`, `appled` |
| Clock | `rtc0` (PCF85363) | system time |
| Watchdog | `watchdog0` | system |

CORE-1 has **no relay or contact ports**. Door, gate and garage relays in a CORE-1 project come from other devices (in the test home, KNX relay actuators and a DoorBird's relay). DirectorLink opens a KNX Contact/Relay device itself, with a pulse, and since 1.10.0 a door or gate on any other relay through Control4's Relay Door, Gate and Garage Door Controller bound to it, with the controller's own Open (ADR-069).

## Sensors

Two temperatures are readable: the processor (`cpu-thermal`, about 60 °C) and the board (TMP75C, about 49 °C), measured during normal use.

## Operating system

- `/etc/os-release`: *Control4 Smart Home OS*, "Control4 Controllers Distro 3.4.4 (honister)". Director itself reports version **3.4.3.727848-res**; the two numbers differ.
- Yocto **Honister** on NXP's i.MX BSP (L5.15.5), kernel **5.15.5+**, preemptible SMP, built with Control4's `aarch64-control4-linux-gcc` 11.2. Packages are Debian-style (`dpkg`/`apt`, about 1300 packages).
- BusyBox userland (so some GNU options are missing), OpenSSH 8.7, `sqlite3`, `curl`, `lua`, `unzip`.
- Main processes: `director` (the Control4 Director, which runs the Lua drivers such as DirectorLink), `broker` (a Node.js service for the apps, driver uploads and the driver cache), `ioserver` (IR and serial), `audio3*` (audio), `led_service`/`appled`.
- Director keeps its project in SQLite databases under `/opt/control4/var/director/` (`project.db`, `state.db`, `identity.db`, `system.db`); installed drivers are in `/mnt/internal/c4z/`; logs are in `/var/log/debug/`.

## Boot chain and security

- **Secure boot is on.** The i.MX High Assurance Boot (HAB) is closed (the SEC_CONFIG fuse is set and Control4's key hash is fused), and both U-Boot (`/boot/imx-boot`) and the kernel (`/boot/Image`) carry Control4 signatures. A custom bootloader or kernel will not start, so **replacing the operating system (e.g. with our own Yocto build) is not possible**.
- **The root file system is not verified**: no dm-verity, IMA or kernel lockdown, and kernel modules are not signed. It is writable by root. DirectorLink never changes it: the driver runs inside Director like any other driver, and is installed with Composer.
- **Factory restore** boots the `recovery` partition, started with the reset pinhole (read by U-Boot on GPIO3_5) or a `RESTORE` file on the boot partition.

## What this means for DirectorLink

- DirectorLink is a Lua driver inside Director. It does not need root access, extra software or changes to the operating system, and must keep working with whatever Control4 ships.
- There is plenty of headroom: 4 cores and about 0.8 GB of free memory, while the driver handles a few requests per second; fetching camera pictures and TLS are done by Director and the hardware crypto.
- Remote access needs one outgoing TLS connection kept open by the driver through Director's network API, as DirectorLink's remote access does (first validated on this CORE-1 in 0.9.0, docs/VALIDATION.md). The CPU's crypto extensions keep TLS cheap.
- Everything the homeowner controls is reached through Director's drivers (KNX, CoolMaster, cameras, …), not through CORE-1 ports, except IR and serial, which Director drives through `ioserver`.

## How this was gathered

All read-only, over SSH as root on the controller:

```sh
tr -d '\0' < /proc/device-tree/model; uname -a; cat /etc/os-release
cat /proc/cpuinfo /proc/meminfo /proc/partitions; df -h
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
cat /sys/block/mmcblk0/device/{name,manfid,oemid,date}
for d in /sys/bus/i2c/devices/*-*; do echo "$d $(cat $d/name)"; done
ls /sys/class/net /sys/class/drm /dev | grep -E 'ttymxc|ttyRPMSG|spidev|rtc|watchdog'
cat /proc/asound/cards; cat /sys/class/thermal/thermal_zone0/temp
ls -l /proc/$(pidof ioserver)/fd      # which ports ioserver opens
```

The boot-chain findings came from the SoC's security fuses (OCOTP: the SEC_CONFIG bit and the fused key hash) and the Control4 signature blocks (CSF) appended to `/boot/imx-boot` and `/boot/Image`.
