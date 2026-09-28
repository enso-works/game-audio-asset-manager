APP := build/Build/Products/Release/Game Audio Asset Manager.app

.PHONY: project build test run install clean

project:
	xcodegen generate

build: project
	xcodebuild -project GameAudioAssetManager.xcodeproj -scheme GameAudioAssetManager -configuration Release -derivedDataPath build build | grep -E "error|warning:|BUILD" || true

test: project
	xcodebuild test -project GameAudioAssetManager.xcodeproj -scheme GameAudioAssetManager -destination 'platform=macOS' -derivedDataPath build-test | grep -E "error:|failed|Executed|TEST (SUCCEEDED|FAILED)" || true

run: build
	open "$(APP)"

install: build
	rm -rf "/Applications/Game Audio Asset Manager.app"
	cp -R "$(APP)" /Applications/

clean:
	rm -rf build build-test build-debug GameAudioAssetManager.xcodeproj
