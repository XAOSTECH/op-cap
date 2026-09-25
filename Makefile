SHIM_SRC  := src/v4l2-hdr-shim.c
SHIM_SO   := src/v4l2-hdr-shim.so
HIDE_SRC  := src/hide_v4l2.c
HIDE_SO   := src/hide_v4l2.so

all: build

build: $(SHIM_SO) $(HIDE_SO)
	@echo "Building usbreset..."
	gcc scripts/usbreset.c -o scripts/usbreset || true
	@[ -f scripts/usbreset ] && echo "  ✓ scripts/usbreset" || echo "  ! usbreset skipped (gcc unavailable)"
	chmod +x scripts/*.sh ffmpeg/*.sh || true
	@echo "Build complete: $(SHIM_SO) $(HIDE_SO) scripts/usbreset"

$(SHIM_SO): $(SHIM_SRC)
	@echo "Building HDR format shim..."
	gcc -shared -fPIC -O2 -o $@ $< -ldl
	@echo "  ✓ $@ built"

$(HIDE_SO): $(HIDE_SRC)
	@echo "Building V4L2 device hide shim (--no-device / sobs)..."
	gcc -shared -fPIC -O2 -o $@ $< -ldl
	@echo "  ✓ $@ built"

shim: $(SHIM_SO)

shim-debug: $(SHIM_SRC)
	gcc -shared -fPIC -O2 -DV4L2_HDR_SHIM_DEBUG -o $(SHIM_SO) $< -ldl
	@echo "✓ v4l2-hdr-shim.so (debug) built at $(SHIM_SO)"

deps:
	@echo "Installing required packages for kernel $$(uname -r)..."
	sudo apt-get install -y ffmpeg v4l-utils usbutils \
	  v4l2loopback-dkms linux-headers-$$(uname -r) vainfo
	@echo "Rebuilding v4l2loopback DKMS module for kernel $$(uname -r)..."
	@V4L2LB_VER=$$(dpkg-query -W -f='$${Version}' v4l2loopback-dkms 2>/dev/null | sed 's/^[^:]*://;s/-.*//'); \
	  [ -n "$$V4L2LB_VER" ] && sudo dkms install "v4l2loopback/$$V4L2LB_VER" -k "$$(uname -r)" 2>/dev/null || true
	@echo "Done. Verify: sudo modprobe v4l2loopback && lsmod | grep v4l2loopback"

install: build
	sudo ./scripts/install.sh

optimise-drivers:
	sudo ./scripts/optimise_drivers.sh --auto

install-with-drivers: build optimise-drivers
	sudo ./scripts/install.sh

validate-capture:
	@if [ -z "$(DEVICE)" ]; then \
		echo "Usage: make validate-capture DEVICE=/dev/video0"; \
		exit 1; \
	fi
	sudo ./scripts/validate_capture.sh $(DEVICE)

optimise-device:
	@if [ -z "$(VIDPID)" ]; then \
		echo "Usage: make optimise-device VIDPID=3188:1000"; \
		exit 1; \
	fi
	sudo ./scripts/optimise_device.sh $(VIDPID)

install-safe-launcher: build
	sudo cp scripts/obs-safe-launch.sh /usr/local/bin/obs-safe-launch
	sudo chmod +x /usr/local/bin/obs-safe-launch
	chmod +x scripts/extract_driver_info.sh || true
	@echo "✓ obs-safe launcher installed to /usr/local/bin/obs-safe-launch"
	@echo "✓ Usage: obs-safe --device /dev/video0 --vidpid 3188:1000"
	@echo ""
	@echo "Note: Use 'obs-safe' directly (wrapper created during driver optimization)"
	@echo "      Or manually: obs-safe-launch --basedir /path/to/op-cap --device /dev/video0"

install-aliases:
	chmod +x scripts/generate_obs_aliases.sh
	./scripts/generate_obs_aliases.sh --basedir "$(CURDIR)"
	@echo "✓ sobs  -> safe OBS with --no-loopback --no-device"
	@echo "✓ cobs  -> list /dev/video*, prompt, safe OBS --device=<selection>"

remove-aliases:
	./scripts/generate_obs_aliases.sh --remove
	@echo "✓ sobs and cobs removed from /usr/local/bin"

extract-driver-info: 
	@./scripts/extract_driver_info.sh

uninstall:
	@sudo ./scripts/uninstall.sh || true

clean:
	rm -f scripts/usbreset $(SHIM_SO) $(HIDE_SO)

distclean: clean uninstall
