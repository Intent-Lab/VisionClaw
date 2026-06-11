/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// HomeScreenView.swift
//
// Welcome screen that guides users through the DAT SDK registration process.
// This view is displayed when the app is not yet registered.
//

import MWDATCore
import SwiftUI

struct HomeScreenView: View {
  @ObservedObject var viewModel: WearablesViewModel
  @State private var showSettings = false

  var body: some View {
    ZStack {
      DesignSystem.colors.deepNavy
        .ignoresSafeArea()

      VStack(spacing: 18) {
        HStack {
          Spacer()
          Button {
            showSettings = true
          } label: {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 18, weight: .semibold))
              .foregroundColor(DesignSystem.colors.vibrantTeal)
              .frame(width: 42, height: 42)
              .background(DesignSystem.colors.surface)
              .overlay(
                RoundedRectangle(cornerRadius: 12)
                  .stroke(DesignSystem.colors.border, lineWidth: 1)
              )
              .clipShape(RoundedRectangle(cornerRadius: 12))
          }
        }

        Spacer(minLength: 0)

        VStack(spacing: 14) {
          Image(.cameraAccessIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 92)
            .padding(18)
            .background(DesignSystem.colors.surface)
            .overlay(
              RoundedRectangle(cornerRadius: 20)
                .stroke(DesignSystem.colors.vibrantTeal.opacity(0.45), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))

          Text("EMBARCADERO WORKER")
            .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
            .foregroundColor(DesignSystem.colors.vibrantTeal)

          Text("Connect your glasses, load today’s package, and execute the next step hands-free.")
            .font(DesignSystem.fonts.body(size: 17))
            .foregroundColor(DesignSystem.colors.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
        }

        VStack(spacing: 12) {
          HomeTipItemView(
            resource: .smartGlassesIcon,
            title: "Assigned SOP Packages",
            text: "Sync your worker queue from ops-api so the current package and SOP line are ready when you begin."
          )
          HomeTipItemView(
            resource: .soundIcon,
            title: "Live Supervisor Support",
            text: "Request jump-in help during an execution and keep the room synced while you stay on task."
          )
          HomeTipItemView(
            resource: .walkingIcon,
            title: "Phone Or Glasses",
            text: "Use Ray-Bans when available, or continue on iPhone without breaking the execution flow."
          )
        }

        Spacer(minLength: 0)

        VStack(spacing: 16) {
          Text("You’ll be redirected to the Meta AI app once to confirm the glasses connection.")
            .font(DesignSystem.fonts.body(size: 14))
            .foregroundColor(DesignSystem.colors.blueGrey)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)

          CustomButton(
            title: viewModel.registrationState == .registering ? "CONNECTING GLASSES..." : "CONNECT RAY-BAN GLASSES",
            style: .primary,
            isDisabled: viewModel.registrationState == .registering
          ) {
            viewModel.connectGlasses()
          }

          CustomButton(
            title: "USE IPHONE CAMERA",
            style: .secondary,
            isDisabled: false
          ) {
            viewModel.skipToIPhoneMode = true
          }
        }
      }
      .padding(.all, 24)
    }
    .sheet(isPresented: $showSettings) {
      SettingsView()
    }
  }

}

struct HomeTipItemView: View {
  let resource: ImageResource
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(resource)
        .resizable()
        .renderingMode(.template)
        .foregroundColor(DesignSystem.colors.vibrantTeal)
        .aspectRatio(contentMode: .fit)
        .frame(width: 24)
        .padding(.leading, 4)
        .padding(.top, 4)

      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(DesignSystem.fonts.mono(size: 16, weight: .semibold))
          .foregroundColor(DesignSystem.colors.white)

        Text(text)
          .font(DesignSystem.fonts.body(size: 14))
          .foregroundColor(DesignSystem.colors.blueGrey)
      }
      Spacer()
    }
    .padding(14)
    .background(DesignSystem.colors.surface)
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(DesignSystem.colors.border, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }
}
