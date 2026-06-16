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
      Color.white.edgesIgnoringSafeArea(.all)

      VStack(spacing: 12) {
        HStack {
          Spacer()
          Button {
            showSettings = true
          } label: {
            Image(systemName: "gearshape")
              .resizable()
              .aspectRatio(contentMode: .fit)
              .foregroundColor(.black)
              .frame(width: 24, height: 24)
          }
        }

        Spacer()

        Image(.cameraAccessIcon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 120)

        VStack(spacing: 6) {
          Text("VisionClaw")
            .font(.system(size: 32, weight: .bold))
            .foregroundColor(.black)

          Text("A real-time AI assistant for your smart glasses. It sees what you see, hears what you say, and takes action — all hands-free.")
            .font(.system(size: 15))
            .foregroundColor(.gray)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)

        VStack(spacing: 12) {
          HomeTipItemView(
            resource: .smartGlassesIcon,
            title: "See what you see",
            text: "The AI looks through your glasses camera and understands the scene in front of you."
          )
          HomeTipItemView(
            resource: .soundIcon,
            title: "Just talk",
            text: "Tap the AI button and speak naturally. Ask questions and get answers out loud."
          )
          HomeTipItemView(
            resource: .tapIcon,
            title: "Take action",
            text: "Send messages, search the web, and manage your lists by voice — powered by OpenClaw."
          )
        }

        Spacer()

        VStack(spacing: 20) {
          Text("You'll be redirected to the Meta AI app to confirm your connection.")
            .font(.system(size: 14))
            .foregroundColor(.gray)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)

          CustomButton(
            title: viewModel.registrationState == .registering ? "Connecting..." : "Connect my glasses",
            style: .primary,
            isDisabled: viewModel.registrationState == .registering
          ) {
            viewModel.connectGlasses()
          }

          CustomButton(
            title: "Start on iPhone",
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
        .foregroundColor(.black)
        .aspectRatio(contentMode: .fit)
        .frame(width: 24)
        .padding(.leading, 4)
        .padding(.top, 4)

      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.system(size: 18, weight: .semibold))
          .foregroundColor(.black)

        Text(text)
          .font(.system(size: 15))
          .foregroundColor(.gray)
      }
      Spacer()
    }
  }
}
