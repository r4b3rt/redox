# Configuration file for QEMU

QEMU=SDL_VIDEO_X11_DGAMOUSE=0 qemu-system-$(QEMU_ARCH)
QEMUFLAGS=-d guest_errors -name "Redox OS $(ARCH)"

ifeq ($(ARCH),i686)
	audio?=ac97
	uefi=no
	QEMU_ARCH=i386
	QEMU_MACHINE?=pc
	QEMU_CPU?=pentium2
	QEMU_SMP?=1
	QEMU_MEM?=1024

	# Default to using kvm when arch is i686 and host is x86_64
	ifeq ($(HOST_ARCH),x86_64)
		kvm?=yes
	endif
else ifeq ($(ARCH),x86_64)
	QEMU_ARCH=x86_64
	QEMU_MACHINE?=q35
	QEMU_CPU?=core2duo
	QEMU_SMP?=4
	QEMU_MEM?=2048
	ifeq ($(uefi),yes)
		FIRMWARE=/usr/share/OVMF/OVMF_CODE.fd
	endif
	ifneq ($(usb),no)
		QEMUFLAGS+=-device nec-usb-xhci,id=xhci
	endif
else ifeq ($(ARCH),aarch64)
	# Default to UEFI as U-Boot doesn't set up a framebuffer for us and we don't yet support
	# setting up a framebuffer ourself.
	uefi?=yes
	live=yes
	QEMU_ARCH=aarch64
	QEMU_MACHINE=virt
	QEMU_CPU=max
	QEMU_SMP?=1
	QEMU_MEM?=2048
	ifeq ($(BOARD),raspi3bp)
		FIRMWARE=$(BUILD)/raspi3bp_uboot.rom
		disk?=sdcard
	else ifeq ($(uefi),yes)
		FIRMWARE=/usr/share/AAVMF/AAVMF_CODE.fd
	else
		FIRMWARE=$(BUILD)/qemu_uboot.rom
	endif
	ifneq ($(gpu),no)
		QEMUFLAGS+=-device ramfb
	endif
	ifneq ($(usb),no)
		QEMUFLAGS+=-device qemu-xhci -device usb-kbd -device usb-tablet
	endif
else
$(error Unsupported ARCH for QEMU "$(ARCH)"))
endif

QEMUFLAGS+=-smp $(QEMU_SMP) -m $(QEMU_MEM)

# If host and target arch do not match, disable kvm
# (unless overridden above or by environment)
ifneq ($(ARCH),$(HOST_ARCH))
	kvm?=no
endif

ifneq ($(FIRMWARE),)
	QEMUFLAGS+=-bios $(FIRMWARE)
endif

ifeq ($(live),yes)
	DISK=$(BUILD)/livedisk.iso
else
	DISK=$(BUILD)/harddrive.img
endif

ifeq ($(serial),no)
	QEMUFLAGS+=-chardev stdio,id=debug -device isa-debugcon,iobase=0x402,chardev=debug
else
	QEMUFLAGS+=-chardev stdio,id=debug,signal=off,mux=on,"$(if $(qemu_serial_logfile),logfile=$(qemu_serial_logfile))"
	QEMUFLAGS+=-serial chardev:debug -mon chardev=debug
endif

ifeq ($(iommu),yes)
	QEMUFLAGS+=-machine $(QEMU_MACHINE),iommu=on
else
	QEMUFLAGS+=-machine $(QEMU_MACHINE)
endif

ifeq ($(audio),no)
	# No audio
else ifeq ($(audio),ac97)
	# AC'97
	QEMUFLAGS+=-device AC97
else
	# Intel High Definition Audio
	QEMUFLAGS+=-device ich9-intel-hda -device hda-output
endif

ifeq ($(net),no)
	QEMUFLAGS+=-net none
else ifeq ($(net),rtl8139)
	# RTL8139
	QEMUFLAGS+=-netdev user,id=net0 -device rtl8139,netdev=net0 \
				-object filter-dump,id=f1,netdev=net0,file=$(BUILD)/network.pcap
else ifeq ($(net),virtio)
	# virtio-net
	QEMUFLAGS+=-netdev user,id=net0 -device virtio-net,netdev=net0 \
				-object filter-dump,id=f1,netdev=net0,file=$(BUILD)/network.pcap
else
	ifneq ($(bridge),)
		QEMUFLAGS+=-netdev bridge,br=$(bridge),id=net0 -device e1000,netdev=net0,id=nic0
	else
	    ifeq ($(net),redir)
			# port 8080 and 8083 - webservers
			# port 64126 - our gdbserver implementation
			QEMUFLAGS+=-netdev user,id=net0,hostfwd=tcp::8080-:8080,hostfwd=tcp::8083-:8083,hostfwd=tcp::64126-:64126 -device e1000,netdev=net0,id=nic0
		else
			QEMUFLAGS+=-netdev user,id=net0 -device e1000,netdev=net0 \
						-object filter-dump,id=f1,netdev=net0,file=$(BUILD)/network.pcap
		endif
	endif
endif

ifeq ($(gpu),no)
	QEMUFLAGS+=-nographic -vga none
else ifeq ($(gpu),multi)
	QEMUFLAGS+=-display sdl -vga std -device secondary-vga
else ifeq ($(gpu),virtio)
	QEMUFLAGS+=-vga virtio
endif

disk?=ata
ifeq ($(disk),ata)
	# For i386, ata will use ided
	# For aarch64 and x86_64, ata will use ahcid
	QEMUFLAGS+= \
		-drive file=$(DISK),format=raw \
		-drive file=$(BUILD)/extra.img,format=raw
else ifeq ($(disk),nvme)
	QEMUFLAGS+= \
		-drive file=$(DISK),format=raw,if=none,id=drv0 -device nvme,drive=drv0,serial=NVME_SERIAL \
		-drive file=$(BUILD)/extra.img,format=raw,if=none,id=drv1 -device nvme,drive=drv1,serial=NVME_EXTRA
else ifeq ($(disk),usb)
	QEMUFLAGS+= \
		-drive if=none,id=usbstick,format=raw,file=$(DISK) \
		-device usb-storage,drive=usbstick
else ifeq ($(disk),virtio)
	QEMUFLAGS+= \
		-drive file=$(DISK),format=raw,if=virtio \
		-drive file=$(BUILD)/extra.img,format=raw,if=virtio
else ifeq ($(disk),cdrom)
	QEMUFLAGS+= \
		-boot d -cdrom $(DISK) \
		-drive file=$(BUILD)/extra.img,format=raw
else ifeq ($(disk),sdcard)
	QEMUFLAGS+=-drive file=$(DISK),if=sd,format=raw
endif

ifeq ($(gdb),yes)
	QEMUFLAGS+=-d cpu_reset -s -S
endif

ifeq ($(UNAME),Linux)
	ifneq ($(kvm),no)
		QEMUFLAGS+=-enable-kvm -cpu host
	else
		QEMUFLAGS+=-cpu $(QEMU_CPU)
	endif
endif

ifeq ($(UNAME),Darwin)
	QEMUFLAGS+=-cpu $(QEMU_CPU)
endif

$(BUILD)/extra.img:
	truncate -s 1g $@

$(BUILD)/raspi3bp_uboot.rom:
	wget -O $@ https://gitlab.redox-os.org/Ivan/redox_firmware/-/raw/main/platform/raspberry_pi/rpi3/u-boot-rpi-3-b-plus.bin

$(BUILD)/qemu_uboot.rom:
	wget -O $@ https://gitlab.redox-os.org/Ivan/redox_firmware/-/raw/main/platform/qemu/qemu_arm64/u-boot-qemu-arm64.bin

/usr/share/AAVMF/AAVMF_CODE.fd:
	echo "\n\n\nMissing /usr/share/AAVMF/AAVMF_CODE.fd UEFI firmware file.\n\
Please install the qemu-efi-aarch64 package or use efi=no to download U-Boot instead.\n" \
	&& exit 1

qemu: $(DISK) $(FIRMWARE) $(BUILD)/extra.img
	$(QEMU) $(QEMUFLAGS)

# You probably want to use disk=no when using the *_extra targets
qemu_extra: $(FIRMWARE) $(BUILD)/extra.img
	$(QEMU) $(QEMUFLAGS) \
		-drive file=$(BUILD)/extra.img,format=raw

qemu_nvme_extra: $(FIRMWARE) $(BUILD)/extra.img
	$(QEMU) $(QEMUFLAGS) \
		-drive file=$(BUILD)/extra.img,format=raw,if=none,id=drv1 -device nvme,drive=drv1,serial=NVME_EXTRA

#additional steps for $(DISK) are required!!!
qemu_raspi: $(FIRMWARE) $(DISK)
	$(QEMU) -M raspi3b -smp 4,cores=1 \
		-kernel $(FIRMWARE) \
		-serial stdio -display none
