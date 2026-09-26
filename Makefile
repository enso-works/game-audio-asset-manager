APP := build/Build/Products/Release/Audio Prepare.app

.PHONY: project build run install clean

project:
	xcodegen generate

build: project
	xcodebuild -project AudioPrepare.xcodeproj -scheme AudioPrepare -configuration Release -derivedDataPath build build | grep -E "error|warning:|BUILD" || true

run: build
	open "$(APP)"

install: build
	rm -rf "/Applications/Audio Prepare.app"
	cp -R "$(APP)" /Applications/

clean:
	rm -rf build AudioPrepare.xcodeproj
