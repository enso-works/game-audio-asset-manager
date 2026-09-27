APP := build/Build/Products/Release/Audio Prepare.app

.PHONY: project build test run install clean

project:
	xcodegen generate

build: project
	xcodebuild -project AudioPrepare.xcodeproj -scheme AudioPrepare -configuration Release -derivedDataPath build build | grep -E "error|warning:|BUILD" || true

test: project
	xcodebuild test -project AudioPrepare.xcodeproj -scheme AudioPrepare -destination 'platform=macOS' -derivedDataPath build-test | grep -E "error:|failed|Executed|TEST (SUCCEEDED|FAILED)" || true

run: build
	open "$(APP)"

install: build
	rm -rf "/Applications/Audio Prepare.app"
	cp -R "$(APP)" /Applications/

clean:
	rm -rf build build-test build-debug AudioPrepare.xcodeproj
