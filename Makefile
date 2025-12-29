.PHONY: help build release run test clean format regenerate preview app uninstall install

SWIFT_FLAGS :=
CLANG_MODULE_CACHE := $(CURDIR)/.clang-module-cache
SWIFT := env CLANG_MODULE_CACHE_PATH=$(CLANG_MODULE_CACHE) swift
PRODUCT := db-viewer
APP_NAME := DBViewer.app
APP_BUILD_DIR := $(CURDIR)/build
APP_BUNDLE := $(APP_BUILD_DIR)/$(APP_NAME)
APP_EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/$(PRODUCT)
APP_INFO_PLIST := $(APP_BUNDLE)/Contents/Info.plist
APP_ICON_SET := $(CURDIR)/Sources/DBViewerApp/Resources/Assets.xcassets/AppIcon.appiconset
APP_ICON := $(APP_BUNDLE)/Contents/Resources/AppIcon.icns

help:
	@echo "利用可能なターゲット:"
	@echo "  make build    - Debugビルド"
	@echo "  make release  - Releaseビルド"
	@echo "  make run      - アプリを実行 (SwiftPM)"
	@echo "  make test     - テスト実行"
	@echo "  make clean    - ビルド成果物削除"
	@echo "  make preview  - SwiftUIプレビュー用にビルド"
	@echo "  make app      - macOSアプリバンドル(.app)を作成"
	@echo "  make install  - /Applicationsにインストール"
	@echo "  make uninstall- /Applicationsとbuildから削除"

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
	@# アイコンを生成 (.iconset -> .icns)
	@rm -rf $(APP_BUILD_DIR)/AppIcon.iconset
	@mkdir -p $(APP_BUILD_DIR)/AppIcon.iconset
	@cp $(APP_ICON_SET)/icon_16x16.png $(APP_BUILD_DIR)/AppIcon.iconset/icon_16x16.png
	@cp $(APP_ICON_SET)/icon_16x16@2x.png $(APP_BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png
	@cp $(APP_ICON_SET)/icon_32x32.png $(APP_BUILD_DIR)/AppIcon.iconset/icon_32x32.png
	@cp $(APP_ICON_SET)/icon_32x32@2x.png $(APP_BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png
	@cp $(APP_ICON_SET)/icon_128x128.png $(APP_BUILD_DIR)/AppIcon.iconset/icon_128x128.png
	@cp $(APP_ICON_SET)/icon_128x128@2x.png $(APP_BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png
	@cp $(APP_ICON_SET)/icon_256x256.png $(APP_BUILD_DIR)/AppIcon.iconset/icon_256x256.png
	@cp $(APP_ICON_SET)/icon_256x256@2x.png $(APP_BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png
	@cp $(APP_ICON_SET)/icon_512x512.png $(APP_BUILD_DIR)/AppIcon.iconset/icon_512x512.png
	@cp $(APP_ICON_SET)/icon_512x512@2x.png $(APP_BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png
	@iconutil -c icns $(APP_BUILD_DIR)/AppIcon.iconset -o $(APP_ICON)
	@rm -rf $(APP_BUILD_DIR)/AppIcon.iconset
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
		'    <key>CFBundleIconFile</key>' \
		'    <string>AppIcon</string>' \
		'</dict>' \
		'</plist>' \
	> $(APP_INFO_PLIST)
	@touch $(APP_BUNDLE)
	@echo "Created $(APP_BUNDLE)"

install: app
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_NAME)"

uninstall:
	@if [ -d "/Applications/$(APP_NAME)" ]; then \
		rm -rf "/Applications/$(APP_NAME)" && echo "Removed /Applications/$(APP_NAME)"; \
	else \
		echo "No app found at /Applications/$(APP_NAME)"; \
	fi
	@if [ -d "$(APP_BUNDLE)" ]; then \
		rm -rf "$(APP_BUNDLE)" && echo "Removed $(APP_BUNDLE)"; \
	else \
		echo "No app bundle found at $(APP_BUNDLE)"; \
	fi
