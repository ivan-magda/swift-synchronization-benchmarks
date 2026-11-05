# SyncBench

This repository contains an iOS harness for comparing Swift synchronization mechanisms on real iPhones.
It records raw samples and run conditions so the measurements can be checked and reproduced.

Status: under construction (milestone 7)

Generate the Xcode project and run the tests on the Simulator:

```bash
xcodegen generate
xcodebuild test -project SyncBench.xcodeproj -scheme SyncBench \
  -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

Compile an unsigned Release build for iOS:

```bash
xcodebuild build -project SyncBench.xcodeproj -scheme SyncBench \
  -configuration Release -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO -quiet
```
