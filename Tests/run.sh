#!/bin/bash
# Builds and runs the DSP self-test (no app, no UI). Pass audio files to analyze them instead.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.4" \
    Sources/Model/Track.swift Sources/Model/TrackAnalysis.swift Sources/Model/MixProject.swift Sources/Audio/AudioDecoder.swift Sources/Analysis/*.swift Sources/Engine/*.swift Tests/main.swift \
    -framework AVFoundation -framework Accelerate -o .build/blend-test
.build/blend-test "$@"
