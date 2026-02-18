all: build

build:
	gcc scripts/usbreset.c -o scripts/usbreset || true
	chmod +x scripts/*.sh || true
	chmod +x ffmpeg/*.sh || true

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

extract-driver-info: 
	@./scripts/extract_driver_info.sh

uninstall:
	@sudo ./scripts/uninstall.sh || true

clean:
	rm -f scripts/usbreset

distclean: clean uninstall
