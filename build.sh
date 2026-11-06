#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=build/Aura.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
swiftc -Osize -wmo -swift-version 5 -target arm64-apple-macos14.4 Sources/main.swift -o $APP/Contents/MacOS/Aura
strip -x $APP/Contents/MacOS/Aura
cp Info.plist $APP/Contents/Info.plist
codesign --force --sign - --identifier dev.xndrpr.aura $APP
du -sh $APP
