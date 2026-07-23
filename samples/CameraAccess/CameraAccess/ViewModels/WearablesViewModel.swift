/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// WearablesViewModel.swift
//
// Primary view model for the CameraAccess app that manages DAT SDK integration.
// Demonstrates how to listen to device availability changes using the DAT SDK's
// device stream functionality and handle permission requests.
//

import CoreBluetooth
import MWDATCore
import SwiftUI

#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

@MainActor
class WearablesViewModel: ObservableObject {
  @Published var devices: [DeviceIdentifier]
  @Published var hasMockDevice: Bool
  @Published var registrationState: RegistrationState
  @Published var showGettingStartedSheet: Bool = false
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var skipToIPhoneMode: Bool = false
  @Published var connectionStatus: String = "Waiting for an active device"

  private var registrationTask: Task<Void, Never>?
  private var deviceStreamTask: Task<Void, Never>?
  private var didRequestCameraPermission = false
  private var setupDeviceStreamTask: Task<Void, Never>?
  private let wearables: WearablesInterface
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var linkStateListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.hasMockDevice = false
    self.registrationState = wearables.registrationState
    NSLog(
      "[Wearables] init registration=%@ devices=%d",
      String(describing: self.registrationState),
      self.devices.count)
    NSLog(
      "[Wearables] bluetooth authorization=%@",
      String(describing: CBManager.authorization))

    // Set up device stream immediately to handle MockDevice events
    setupDeviceStreamTask = Task {
      await setupDeviceStream()
    }

    registrationTask = Task {
      for await registrationState in wearables.registrationStateStream() {
        let previousState = self.registrationState
        self.registrationState = registrationState
        NSLog(
          "[Wearables] registration %@ -> %@",
          String(describing: previousState),
          String(describing: registrationState))
        if self.showGettingStartedSheet == false && registrationState == .registered && previousState == .registering {
          self.showGettingStartedSheet = true
        }
        // Per Meta DAT docs: a wearable will NOT appear in devicesStream until at least one
        // permission (camera) is granted via the Meta AI app. The stock app only requests it
        // inside handleStartStreaming(), which is gated behind a button disabled until a device
        // appears — a deadlock. Request it as soon as we're registered so the glasses show up.
        if registrationState == .registered {
          requestCameraPermissionIfNeeded()
        }
      }
    }
  }

  deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
    setupDeviceStreamTask?.cancel()
  }

  private func setupDeviceStream() async {
    if let task = deviceStreamTask, !task.isCancelled {
      task.cancel()
    }

    deviceStreamTask = Task {
      for await devices in wearables.devicesStream() {
        self.devices = devices
        NSLog("[Wearables] devices stream count=%d", devices.count)
        if devices.isEmpty {
          connectionStatus = "Waiting for an active device"
        }
        // Already-registered launch with no devices yet: still need the camera permission grant.
        if devices.isEmpty && self.registrationState == .registered {
          requestCameraPermissionIfNeeded()
        }
        #if canImport(MWDATMockDevice)
        self.hasMockDevice = !MockDeviceKit.shared.pairedDevices.isEmpty
        #endif
        monitorDeviceState(devices: devices)
      }
    }
  }

  private func monitorDeviceState(devices: [DeviceIdentifier]) {
    // Remove listeners for devices that are no longer present
    let deviceSet = Set(devices)
    compatibilityListenerTokens = compatibilityListenerTokens.filter { deviceSet.contains($0.key) }
    linkStateListenerTokens = linkStateListenerTokens.filter { deviceSet.contains($0.key) }

    // Add listeners for new devices
    for deviceId in devices {
      guard let device = wearables.deviceForIdentifier(deviceId) else { continue }

      let deviceName = device.nameOrId()
      connectionStatus = Self.connectionStatus(for: device.linkState, deviceName: deviceName)
      NSLog(
        "[Wearables] device name=%@ type=%@ link=%@ compatibility=%@",
        deviceName,
        device.deviceType().rawValue,
        String(describing: device.linkState),
        String(describing: device.compatibility()))

      if compatibilityListenerTokens[deviceId] == nil {
        let token = device.addCompatibilityListener { [weak self] compatibility in
          NSLog(
            "[Wearables] compatibility device=%@ state=%@",
            deviceName,
            String(describing: compatibility))
          guard let self else { return }
          if compatibility == .deviceUpdateRequired {
            Task { @MainActor in
              self.showError("Device '\(deviceName)' requires an update to work with this app")
            }
          }
        }
        compatibilityListenerTokens[deviceId] = token
      }

      if linkStateListenerTokens[deviceId] == nil {
        let token = device.addLinkStateListener { [weak self] linkState in
          NSLog(
            "[Wearables] link state device=%@ state=%@",
            deviceName,
            String(describing: linkState))
          Task { @MainActor in
            self?.connectionStatus = Self.connectionStatus(
              for: linkState,
              deviceName: deviceName)
            if Self.shouldRetryCameraPermission(for: linkState) {
              self?.requestCameraPermissionIfNeeded()
            }
          }
        }
        linkStateListenerTokens[deviceId] = token
      }

      if Self.shouldRetryCameraPermission(for: device.linkState) {
        requestCameraPermissionIfNeeded()
      }
    }
  }

  nonisolated static func shouldRetryCameraPermission(for linkState: LinkState) -> Bool {
    linkState == .connected
  }

  nonisolated static func connectionStatus(
    for linkState: LinkState,
    deviceName: String
  ) -> String {
    switch linkState {
    case .disconnected:
      return "\(deviceName) found, but disconnected in Meta AI"
    case .connecting:
      return "\(deviceName) found — completing Meta connection"
    case .connected:
      return "\(deviceName) connected"
    }
  }

  /// Request glasses camera permission via the Meta AI app. Required for the wearable to appear
  /// in devicesStream at all (per Meta DAT docs). Guarded so it only fires once per session.
  func requestCameraPermissionIfNeeded() {
    guard !didRequestCameraPermission else { return }
    didRequestCameraPermission = true
    Task { @MainActor in
      do {
        let status = try await wearables.checkPermissionStatus(Permission.camera)
        NSLog("[Wearables] camera permission status=%@", String(describing: status))
        if status != .granted {
          let requestedStatus = try await wearables.requestPermission(Permission.camera)
          NSLog(
            "[Wearables] camera permission request result=%@",
            String(describing: requestedStatus))
        }
      } catch {
        NSLog("[Wearables] camera permission flow failed: %@", error.localizedDescription)
        self.didRequestCameraPermission = false  // allow a retry on error
      }
    }
  }

  func connectGlasses() {
    guard registrationState != .registering else { return }
    Task { @MainActor in
      do {
        try await wearables.startRegistration()
      } catch let error as RegistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func disconnectGlasses() {
    Task { @MainActor in
      do {
        try await wearables.startUnregistration()
      } catch let error as UnregistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func openDATGlassesAppUpdate() {
    Task { @MainActor in
      do {
        try await wearables.openDATGlassesAppUpdate()
      } catch let error as NavigationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func showError(_ error: String) {
    errorMessage = error
    showError = true
  }

  func dismissError() {
    showError = false
  }
}
