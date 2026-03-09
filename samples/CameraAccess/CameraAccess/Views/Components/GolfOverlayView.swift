import MapKit
import SwiftUI

// MARK: - Golf Overlay (full overlay shown during golf session)

struct GolfOverlay: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    VStack(spacing: 0) {
      // Top bar: golf pill + course name + status + score badge
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          GolfModePill()
          if let state = geminiVM.golfState, !state.courseName.isEmpty {
            Text(state.courseName)
              .font(.system(size: 11, weight: .medium))
              .foregroundColor(.white.opacity(0.5))
              .lineLimit(1)
          }
        }
        GeminiStatusBar(geminiVM: geminiVM)
        Spacer()
        // Mini map toggle
        Button(action: { geminiVM.toggleMiniMap() }) {
          Image(systemName: geminiVM.golfState?.showMiniMap == true ? "map.fill" : "map")
            .font(.system(size: 14))
            .foregroundColor(.green)
            .padding(8)
            .background(Color.black.opacity(0.5))
            .clipShape(Circle())
        }
        if let state = geminiVM.golfState {
          ScoreToParBadge(scoreToPar: state.scoreToPar, thruHole: state.currentHole > 1 ? state.currentHole - 1 : 0)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)

      // Course confirmation banner
      if let state = geminiVM.golfState, state.courseLoaded && !state.courseConfirmed {
        CourseConfirmationBanner(
          courseName: state.courseName,
          nearbyCourses: state.nearbyCoursesForPicker,
          onConfirm: { geminiVM.confirmGolfCourse() },
          onSelect: { course in Task { await geminiVM.selectGolfCourse(course) } }
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
      }

      // Mini satellite map
      if let state = geminiVM.golfState, state.showMiniMap {
        GolfMiniMap(state: state, locationManager: geminiVM.locationManagerAccess)
          .frame(height: 180)
          .cornerRadius(14)
          .overlay(
            RoundedRectangle(cornerRadius: 14)
              .stroke(Color.green.opacity(0.3), lineWidth: 1)
          )
          .padding(.horizontal, 16)
          .padding(.top, 8)
      }

      Spacer()

      // Transcript + tool status + speaking indicator
      VStack(spacing: 8) {
        if !geminiVM.userTranscript.isEmpty || !geminiVM.aiTranscript.isEmpty {
          TranscriptView(
            userText: geminiVM.userTranscript,
            aiText: geminiVM.aiTranscript
          )
        }

        ToolCallStatusView(status: geminiVM.toolCallStatus)

        if geminiVM.isModelSpeaking {
          HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
              .foregroundColor(.white)
              .font(.system(size: 14))
            SpeakingIndicator()
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(Color.black.opacity(0.5))
          .cornerRadius(20)
        }
      }

      // Bottom HUD: hole info card
      if let state = geminiVM.golfState {
        GolfHoleCard(state: state)
          .padding(.horizontal, 16)
          .padding(.top, 8)
      }

      Spacer(minLength: 0)
    }
    .padding(.bottom, 80)
    .padding(.horizontal, 8)
  }
}

// MARK: - Course Confirmation Banner

struct CourseConfirmationBanner: View {
  let courseName: String
  let nearbyCourses: [GolfCourse]
  let onConfirm: () -> Void
  let onSelect: (GolfCourse) -> Void
  @State private var showPicker = false

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "location.fill")
          .foregroundColor(.green)
          .font(.system(size: 14))
        Text("Detected: **\(courseName)**")
          .font(.system(size: 14))
          .foregroundColor(.white)
        Spacer()
      }
      HStack(spacing: 12) {
        Button(action: onConfirm) {
          HStack(spacing: 4) {
            Image(systemName: "checkmark")
              .font(.system(size: 12, weight: .bold))
            Text("Confirm")
              .font(.system(size: 13, weight: .semibold))
          }
          .foregroundColor(.white)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(Color.green)
          .cornerRadius(8)
        }
        if nearbyCourses.count > 1 {
          Button(action: { showPicker = true }) {
            HStack(spacing: 4) {
              Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12))
              Text("Change")
                .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.green)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.15))
            .cornerRadius(8)
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green.opacity(0.4), lineWidth: 1)
            )
          }
        }
        Spacer()
      }

      // Nearby courses picker
      if showPicker {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(nearbyCourses, id: \.id) { course in
            Button(action: {
              showPicker = false
              onSelect(course)
            }) {
              HStack {
                Text(course.name)
                  .font(.system(size: 13))
                  .foregroundColor(.white)
                Spacer()
                if !course.city.isEmpty {
                  Text(course.city)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                }
              }
              .padding(.vertical, 6)
              .padding(.horizontal, 10)
              .background(course.name == courseName ? Color.green.opacity(0.2) : Color.clear)
              .cornerRadius(6)
            }
          }
        }
        .padding(.top, 4)
      }
    }
    .padding(12)
    .background(Color.black.opacity(0.8))
    .cornerRadius(12)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.green.opacity(0.4), lineWidth: 1)
    )
  }
}

// MARK: - Golf Mini Map (satellite view with position + green pin)

struct GolfMiniMap: View {
  let state: GolfState
  let locationManager: LocationManager?

  var body: some View {
    GolfMapRepresentable(
      userCoord: locationManager?.lastCoordinate,
      greenCoord: greenCoordinate,
      courseName: state.courseName
    )
  }

  private var greenCoordinate: CLLocationCoordinate2D? {
    guard let holeData = state.holesData.first(where: { $0.number == state.currentHole }),
          let lat = holeData.greenLatitude,
          let lng = holeData.greenLongitude else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lng)
  }
}

struct GolfMapRepresentable: UIViewRepresentable {
  let userCoord: CLLocationCoordinate2D?
  let greenCoord: CLLocationCoordinate2D?
  let courseName: String

  func makeUIView(context: Context) -> MKMapView {
    let map = MKMapView()
    map.mapType = .satellite
    map.isUserInteractionEnabled = false
    map.showsUserLocation = true
    map.isZoomEnabled = false
    map.isScrollEnabled = false
    return map
  }

  func updateUIView(_ map: MKMapView, context: Context) {
    // Remove old annotations
    map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })

    // Center on user or green
    if let user = userCoord {
      let region: MKCoordinateRegion
      if let green = greenCoord {
        // Show both user and green
        let centerLat = (user.latitude + green.latitude) / 2
        let centerLng = (user.longitude + green.longitude) / 2
        let latDelta = abs(user.latitude - green.latitude) * 1.8 + 0.001
        let lngDelta = abs(user.longitude - green.longitude) * 1.8 + 0.001
        region = MKCoordinateRegion(
          center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
          span: MKCoordinateSpan(latitudeDelta: max(latDelta, 0.002), longitudeDelta: max(lngDelta, 0.002))
        )
        // Green pin
        let pin = MKPointAnnotation()
        pin.coordinate = green
        pin.title = "Green"
        map.addAnnotation(pin)
      } else {
        region = MKCoordinateRegion(
          center: user,
          span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        )
      }
      map.setRegion(region, animated: false)
    }
  }
}

// MARK: - Golf Mode Pill (green pulsing indicator)

struct GolfModePill: View {
  @State private var pulsing = false

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(Color.green)
        .frame(width: 8, height: 8)
        .scaleEffect(pulsing ? 1.3 : 1.0)
        .animation(
          .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
          value: pulsing
        )
      Image(systemName: "flag.fill")
        .font(.system(size: 10))
        .foregroundColor(.green)
      Text("Golf")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.green)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.green.opacity(0.15))
    .cornerRadius(16)
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(Color.green.opacity(0.4), lineWidth: 1)
    )
    .onAppear { pulsing = true }
  }
}

// MARK: - Score To Par Badge (top-right corner)

struct ScoreToParBadge: View {
  let scoreToPar: Int
  let thruHole: Int

  private var scoreText: String {
    if scoreToPar == 0 { return "E" }
    return scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
  }

  private var scoreColor: Color {
    if scoreToPar < 0 { return .red }
    if scoreToPar == 0 { return .white }
    return .yellow
  }

  var body: some View {
    VStack(spacing: 1) {
      Text(scoreText)
        .font(.system(size: 20, weight: .bold, design: .rounded))
        .foregroundColor(scoreColor)
      if thruHole > 0 {
        Text("thru \(thruHole)")
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(.white.opacity(0.6))
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.black.opacity(0.7))
    .cornerRadius(12)
  }
}

// MARK: - Golf Hole Card (bottom HUD)

struct GolfHoleCard: View {
  let state: GolfState

  private var distText: String {
    if let dist = state.distanceToGreen {
      return "\(dist)y"
    }
    return "—"
  }

  var body: some View {
    HStack(spacing: 0) {
      cardItem(label: "HOLE", value: "\(state.currentHole)")
      divider
      cardItem(label: "PAR", value: state.par > 0 ? "\(state.par)" : "—")
      divider
      distItem(label: "DIST", value: distText)
      divider
      cardItem(label: "WIND", value: state.wind.isEmpty ? "—" : state.wind)
      divider
      clubItem(label: "CLUB", value: state.recommendedClub.isEmpty ? "—" : state.recommendedClub)
    }
    .background(Color.black.opacity(0.75))
    .cornerRadius(14)
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(Color.green.opacity(0.3), lineWidth: 1)
    )
  }

  private func cardItem(label: String, value: String) -> some View {
    VStack(spacing: 3) {
      Text(label)
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.green.opacity(0.7))
      Text(value)
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .foregroundColor(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
  }

  private func distItem(label: String, value: String) -> some View {
    VStack(spacing: 3) {
      Text(label)
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.green.opacity(0.7))
      Text(value)
        .font(.system(size: 18, weight: .bold, design: .rounded))
        .foregroundColor(.green)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
  }

  private func clubItem(label: String, value: String) -> some View {
    VStack(spacing: 3) {
      Text(label)
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.cyan.opacity(0.7))
      Text(value)
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .foregroundColor(.cyan)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.15))
      .frame(width: 1, height: 30)
  }
}

// MARK: - Golf Mode Button (for controls bar)

struct GolfModeButton: View {
  @ObservedObject var geminiVM: GeminiSessionViewModel

  var body: some View {
    Button(action: {
      Task {
        if geminiVM.isGeminiActive && geminiVM.sessionMode == .golf {
          geminiVM.stopSession()
        } else if !geminiVM.isGeminiActive {
          await geminiVM.startGolfSession()
        }
      }
    }) {
      VStack(spacing: 2) {
        Image(systemName: geminiVM.sessionMode == .golf ? "flag.circle.fill" : "flag.circle")
          .font(.system(size: 14))
        Text("Golf")
          .font(.system(size: 10, weight: .medium))
      }
    }
    .foregroundColor(geminiVM.sessionMode == .golf ? .white : .black)
    .frame(width: 56, height: 56)
    .background(geminiVM.sessionMode == .golf ? Color.green : .white)
    .clipShape(Circle())
    .opacity(geminiVM.isGeminiActive && geminiVM.sessionMode != .golf ? 0.4 : 1.0)
    .disabled(geminiVM.isGeminiActive && geminiVM.sessionMode != .golf)
  }
}
