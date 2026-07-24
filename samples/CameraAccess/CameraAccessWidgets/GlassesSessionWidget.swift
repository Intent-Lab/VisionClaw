import SwiftUI
import WidgetKit

private enum GlassesSessionWidgetDestination {
  static let url = URL(string: "visionclaw://glasses-session")!
}

private struct GlassesSessionWidgetEntry: TimelineEntry {
  let date: Date
}

private struct GlassesSessionWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> GlassesSessionWidgetEntry {
    GlassesSessionWidgetEntry(date: Date())
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (GlassesSessionWidgetEntry) -> Void
  ) {
    completion(GlassesSessionWidgetEntry(date: Date()))
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<GlassesSessionWidgetEntry>) -> Void
  ) {
    completion(
      Timeline(
        entries: [GlassesSessionWidgetEntry(date: Date())],
        policy: .never
      )
    )
  }
}

private struct GlassesSessionWidgetView: View {
  @Environment(\.widgetFamily) private var widgetFamily

  var body: some View {
    Group {
      switch widgetFamily {
      case .accessoryCircular:
        ZStack {
          AccessoryWidgetBackground()
          Image(systemName: "eyeglasses")
            .font(.title2)
        }
      case .accessoryRectangular:
        HStack(spacing: 8) {
          Image(systemName: "eyeglasses")
            .font(.title3)
          VStack(alignment: .leading, spacing: 1) {
            Text("Open VisionClaw")
              .font(.headline)
            Text("App opens to start")
              .font(.caption2)
          }
        }
      default:
        Image(systemName: "eyeglasses")
      }
    }
    .containerBackground(.clear, for: .widget)
    .widgetURL(GlassesSessionWidgetDestination.url)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Open Glasses Session")
    .accessibilityHint(
      "Opens VisionClaw. The foreground app is required to start the session."
    )
  }
}

@main
struct GlassesSessionWidget: Widget {
  private let kind = "OpenGlassesSessionWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: kind,
      provider: GlassesSessionWidgetProvider()
    ) { _ in
      GlassesSessionWidgetView()
    }
    .configurationDisplayName("Open Glasses Session")
    .description(
      "Opens VisionClaw in the foreground so you can start a glasses session."
    )
    .supportedFamilies([.accessoryCircular, .accessoryRectangular])
  }
}
