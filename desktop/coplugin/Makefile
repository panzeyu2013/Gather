SDK_PATH := ../../Capture_One_Plugin_SDK_(Mac)_v1.0.1
FRAMEWORK_PATH := $(SDK_PATH)/Library/Frameworks
PRODUCT := GatherLink.coplugin
# The packaged app's architecture. overridden by the afterPack hook, which
# passes TARGET_ARCH (x86_64 / arm64) matching the app build.
TARGET_ARCH ?= arm64
# minos 与 app 部署目标一致（app 只支持 macOS 26+）；build.sh 会再显式覆盖一次。
TARGET := $(TARGET_ARCH)-apple-macosx26.0
# Quote the framework path: the SDK directory name contains parentheses,
# which otherwise break the generated shell command.
SWIFT_FLAGS := -F "$(FRAMEWORK_PATH)" -framework CaptureOnePlugins -framework Cocoa -Xlinker -rpath -Xlinker "$(FRAMEWORK_PATH)"

.PHONY: all clean install

all: $(PRODUCT)

# 问题 11（第三轮审查）：旧规则没有前置依赖 —— 产物目录一存在就不再重编译，
# 改源码/改 plist/切架构都复用旧插件。这里以二进制与架构戳为真实目标。
$(PRODUCT): $(PRODUCT)/Contents/MacOS/GatherLink $(PRODUCT)/Contents/Info.plist $(PRODUCT)/.arch-$(TARGET_ARCH)

$(PRODUCT)/.arch-$(TARGET_ARCH):
	@mkdir -p "$(PRODUCT)/Contents/MacOS"
	@rm -f "$(PRODUCT)"/.arch-*
	@touch "$@"

$(PRODUCT)/Contents/MacOS/GatherLink: GatherLink/GatherLink.swift $(PRODUCT)/.arch-$(TARGET_ARCH)
	@mkdir -p "$(PRODUCT)/Contents/MacOS"
	swiftc $(SWIFT_FLAGS) \
		-target $(TARGET) \
		-o "$@" \
		GatherLink/GatherLink.swift

$(PRODUCT)/Contents/Info.plist: GatherLink/Info.plist
	@mkdir -p "$(PRODUCT)/Contents"
	cp "$<" "$@"

install: $(PRODUCT)
	@C1_PLUGINS_DIR="$$HOME/Library/Application Support/Capture One/Plug-ins"; \
	mkdir -p "$$C1_PLUGINS_DIR"; \
	rm -rf "$$C1_PLUGINS_DIR/$(PRODUCT)"; \
	cp -R "$(PRODUCT)" "$$C1_PLUGINS_DIR/"; \
	echo "Installed to $$C1_PLUGINS_DIR/$(PRODUCT)"
	@echo "Restart Capture One to load the plugin."

clean:
	rm -rf $(PRODUCT)
