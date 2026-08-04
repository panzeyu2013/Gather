SDK_PATH := ../../Capture_One_Plugin_SDK_(Mac)_v1.0.1
FRAMEWORK_PATH := $(SDK_PATH)/Library/Frameworks
PRODUCT := GatherLink.coplugin
# The packaged app's architecture. overridden by the afterPack hook, which
# passes TARGET_ARCH (x86_64 / arm64) matching the app build.
TARGET_ARCH ?= arm64
TARGET := $(TARGET_ARCH)-apple-macosx10.14
# Quote the framework path: the SDK directory name contains parentheses,
# which otherwise break the generated shell command.
SWIFT_FLAGS := -F "$(FRAMEWORK_PATH)" -framework CaptureOnePlugins -framework Cocoa -Xlinker -rpath -Xlinker "$(FRAMEWORK_PATH)"

.PHONY: all clean install

all: $(PRODUCT)

$(PRODUCT):
	mkdir -p "$@/Contents/MacOS"
	cp GatherLink/Info.plist "$@/Contents/"
	swiftc $(SWIFT_FLAGS) \
		-target $(TARGET) \
		-o "$@/Contents/MacOS/GatherLink" \
		GatherLink/GatherLink.swift

install: $(PRODUCT)
	@C1_PLUGINS_DIR="$$HOME/Library/Application Support/Capture One/Plug-ins"; \
	mkdir -p "$$C1_PLUGINS_DIR"; \
	rm -rf "$$C1_PLUGINS_DIR/$(PRODUCT)"; \
	cp -R "$(PRODUCT)" "$$C1_PLUGINS_DIR/"; \
	echo "Installed to $$C1_PLUGINS_DIR/$(PRODUCT)"
	@echo "Restart Capture One to load the plugin."

clean:
	rm -rf $(PRODUCT)
