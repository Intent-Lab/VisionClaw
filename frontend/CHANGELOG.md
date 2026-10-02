# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-02-03

> **Note:** This version requires updated configuration values from Wearables Developer Center to work with release channels.

### Added

- Meta Ray-Ban Display glasses support.
- [API] `hingesClosed` value in `StreamSessionError`.
- [API] `UnregistrationError`, and moved some values from `RegistrationError` to it.
- [API] `networkUnavailable` value in `RegistrationError`.
- [API] `WearablesHandleURLError`.

### Changed

- `MWDATCore` types are now `Sendable`, making the SDK thread-safe.

### Fixed

- Fixed streaming status when switching between devices.
- Fixed streaming status failing to get to `Streaming` due to a race condition.

## [0.3.0] - 2025-12-16

### Changed

- [API] In `PermissionError`, `companionAppNotInstalled` has been renamed to `metaAINotInstalled`.
- Relaxed constraints to API methods, allowing some to run outside `@MainActor`.
- The Camera Access app streaming UI reflects device availability.
- The Camera Access app shows errors when incompatible glasses are found.
- The Camera Access app can now run in background mode, without interrupting streaming (but stopping video decoding).

### Fixed

- Streaming status is set to `stopped` if permission is not granted.
- Fixed UI issues in the Camera Access app.

## [0.2.1] - 2025-12-04

### Added

- [API] Raw `CMSampleBuffer` to `VideoFrame`.

### Changed

- The SDK does not require setting `CFBundleDisplayName` in the app's `Info.plist` during development.

### Fixed

- Streaming can now continue when the app is in background mode.

## [0.2.0] - 2025-11-18

### Added

- [API] New `compatibility` method in `Device`.
- [API] `addCompatibilityListener` to react to compatibility changes.
- [API] Convenience initializer on `StreamSession` enabling user provided `StreamSessionConfig`.
- Description to enum types and made them `CustomStringConvertible` for easier printing.

### Changed

- [API] The SDK is now split into separate components, allowing independent inclusion in projects as needed.
- [API] Obj-C functions no longer use typed throws; they now throw only `Error`.
- [API] Permission API updated for better consistency with Android:
  - `isPermissionGranted` renamed to `checkPermissionStatus`, returning `PermissionStatus` instead of `Bool`.
  - `requestPermission` now returns `PermissionStatus` instead of `Bool`.
  - Added `PermissionStatus` with values `granted` and `denied`, instead of the `Bool` used before.
  - Updated `PermissionError` values.
- [API] `RegistrationError` now holds different errors, aligning more closely with the Android SDK.
- [API] Renamed `DeviceType` enum values.
- [API] Replaced `MockDevice` `UUID` with `DeviceIdentifier`.
- Updated `StreamingResolution.Medium` from 540x960 to 504x896 to match Android.
- `AutoDeviceSelector` now selects or drops devices based on connectivity state.
- Adaptive Bit Rate (streaming) now works with the provided resolution and frame rate hints.
- Camera Access app redesigned and updated to the current SDK version.

### Removed

- [API] `androidPermission` property from `Permission`.
- [API] `prepare` method from `StreamSession`.

### Fixed

- Fixed issue where sessions sometimes failed to close when connection with glasses was lost.

## [0.1.0] - 2025-10-30

### Added

- First version of the Wearables Device Access Toolkit for iOS.
