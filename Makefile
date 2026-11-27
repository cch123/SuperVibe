.PHONY: build bundle run debug debug-prompt test test-asr clean

APP_NAME = SuperVibe

build:
	swift build -c release

bundle: build
	@BIN_PATH=$$(swift build -c release --show-bin-path) && \
	mkdir -p $(APP_NAME).app/Contents/MacOS && \
	mkdir -p $(APP_NAME).app/Contents/Resources && \
	cp "$$BIN_PATH/$(APP_NAME)" $(APP_NAME).app/Contents/MacOS/ && \
	cp Info.plist $(APP_NAME).app/Contents/ && \
	if [ -d "$$BIN_PATH/SuperVibe_SuperVibe.bundle" ]; then \
		cp -R "$$BIN_PATH/SuperVibe_SuperVibe.bundle" $(APP_NAME).app/Contents/Resources/; \
	fi && \
	echo "APPL????" > $(APP_NAME).app/Contents/PkgInfo && \
	codesign --force --sign - $(APP_NAME).app && \
	echo "Built & signed $(APP_NAME).app"

run: build
	@BIN_PATH=$$(swift build -c release --show-bin-path) && \
	"$$BIN_PATH/$(APP_NAME)"

# Unit tests (no model required).
test:
	swift test

# End-to-end ASR test against the real server and model:
#   make test-asr WAV=/path/to/24kHz-mono-int16.wav [EXPECT=substring]
test-asr:
	SUPERVIBE_ASR_TEST_WAV="$(WAV)" SUPERVIBE_ASR_TEST_EXPECT="$(EXPECT)" swift test --filter ASRServerTests

debug:
	swift build
	@BIN_PATH=$$(swift build --show-bin-path) && \
	"$$BIN_PATH/$(APP_NAME)"

# Same as `debug` but also dumps the full LLM prompt (ambient + profile +
# corrections + instruction) to stderr for every polish/translate request.
debug-prompt:
	swift build
	@BIN_PATH=$$(swift build --show-bin-path) && \
	SUPERVIBE_LLM_DUMP_PROMPT=1 "$$BIN_PATH/$(APP_NAME)"

clean:
	swift package clean
	rm -rf $(APP_NAME).app
