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

uninstall:
	@sudo ./scripts/uninstall.sh || true

clean:
	rm -f scripts/usbreset

distclean: clean uninstall
