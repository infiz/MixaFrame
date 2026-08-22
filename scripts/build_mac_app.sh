#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

xcodebuild \
  -project MixaFrame.xcodeproj \
  -scheme MixaFrameMac \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
