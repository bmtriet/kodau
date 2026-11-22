# Kodau developer shortcuts. Uses full Xcode when available (CommandLineTools alone lacks the `Testing` module).
XCODE_DEV := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR ?= $(shell [ -d "$(XCODE_DEV)" ] && echo "$(XCODE_DEV)")

.PHONY: build test bench app install signing clean

build:            ## Debug build of all targets
	swift build

test:             ## Run the unit test suite
	swift test

bench:            ## Offline diacritic accuracy on Tests/Corpus (ARGS="--update-baseline" to re-record)
	swift run KodauBench $(ARGS)

app:              ## Package build/Kodau.app (release)
	./scripts/build_app.sh

install:          ## Build + install KodauIM into ~/Library/Input Methods and rebuild Kodau.app
	./scripts/install_im.sh

signing:          ## One-time: create the stable local code signing identity
	./scripts/setup_signing.sh

clean:
	rm -rf .build build
