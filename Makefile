.PHONY: help build release run test clean format regenerate preview app uninstall

SWIFT_FLAGS :=
CLANG_MODULE_CACHE := $(CURDIR)/.clang-module-cache
SWIFT := env CLANG_MODULE_CACHE_PATH=$(CLANG_MODULE_CACHE) swift
PRODUCT := db-viewer
APP_NAME := DBViewer.app
APP_BUILD_DIR := $(CURDIR)/build
APP_BUNDLE := $(APP_BUILD_DIR)/$(APP_NAME)
APP_EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/$(PRODUCT)
APP_INFO_PLIST := $(APP_BUNDLE)/Contents/Info.plist

help:
	@echo "利用可能なターゲット:"
	@echo "  make build    - Debugビルド"
	@echo "  make release  - Releaseビルド"
	@echo "  make run      - アプリを実行 (SwiftPM)"
	@echo "  make test     - テスト実行"
	@echo "  make clean    - ビルド成果物削除"
	@echo "  make preview  - SwiftUIプレビュー用にビルド"

build:
	@mkdir -p $(CLANG_MODULE_CACHE)
	$(SWIFT) build --disable-sandbox $(SWIFT_FLAGS)

release:
	@mkdir -p $(CLANG_MODULE_CACHE)
	$(SWIFT) build --disable-sandbox -c release $(SWIFT_FLAGS)

run:
	@mkdir -p $(CLANG_MODULE_CACHE)
	$(SWIFT) run --disable-sandbox $(SWIFT_FLAGS) $(PRODUCT)

preview:
	@mkdir -p $(CLANG_MODULE_CACHE)
	$(SWIFT) build --disable-sandbox --target DBViewerApp $(SWIFT_FLAGS)

test:
	@mkdir -p $(CLANG_MODULE_CACHE)
	$(SWIFT) test --disable-sandbox $(SWIFT_FLAGS)

clean:
	$(SWIFT) package clean

app: release
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(dir $(APP_EXECUTABLE))
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp .build/release/$(PRODUCT) $(APP_EXECUTABLE)
	@chmod +x $(APP_EXECUTABLE)
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>CFBundleDevelopmentRegion</key>' \
		'    <string>en</string>' \
		'    <key>CFBundleName</key>' \
		'    <string>DBViewer</string>' \
		'    <key>CFBundleDisplayName</key>' \
		'    <string>DBViewer</string>' \
		'    <key>CFBundleIdentifier</key>' \
		'    <string>com.yuorei.dbviewer</string>' \
		'    <key>CFBundleVersion</key>' \
		'    <string>1.0</string>' \
		'    <key>CFBundleShortVersionString</key>' \
		'    <string>1.0</string>' \
		'    <key>CFBundleExecutable</key>' \
		'    <string>$(PRODUCT)</string>' \
		'    <key>CFBundlePackageType</key>' \
		'    <string>APPL</string>' \
		'    <key>CFBundleSignature</key>' \
		'    <string>????</string>' \
		'    <key>CFBundleSupportedPlatforms</key>' \
		'    <array>' \
		'        <string>MacOSX</string>' \
		'    </array>' \
		'    <key>LSMinimumSystemVersion</key>' \
		'    <string>13.0</string>' \
		'    <key>NSPrincipalClass</key>' \
		'    <string>NSApplication</string>' \
		'    <key>NSHighResolutionCapable</key>' \
		'    <true/>' \
		'</dict>' \
		'</plist>' \
	> $(APP_INFO_PLIST)
	@touch $(APP_BUNDLE)
	@echo "Created $(APP_BUNDLE)"

uninstall:
	@if [ -d "$(APP_BUNDLE)" ]; then \
		rm -rf "$(APP_BUNDLE)" && echo "Removed $(APP_BUNDLE)"; \
	else \
		echo "No app bundle found at $(APP_BUNDLE)"; \
	fi
