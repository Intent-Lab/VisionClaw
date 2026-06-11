import SwiftUI

struct HistoryView: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if viewModel.shippedHistory.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("NO EXECUTIONS YET")
              .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
              .foregroundColor(DesignSystem.colors.vibrantTeal)
            Text("Completed sessions will appear here after you finish a run.")
              .font(DesignSystem.fonts.body(size: 14))
              .foregroundColor(DesignSystem.colors.blueGrey)
          }
          .brutalistCard(stroke: DesignSystem.colors.blueGrey)
        } else {
          ForEach(viewModel.shippedHistory) { session in
            VStack(alignment: .leading, spacing: 6) {
              Text(session.sopName)
                .font(DesignSystem.fonts.mono(size: 16, weight: .semibold))
                .foregroundColor(DesignSystem.colors.white)

              Text(session.timestampText)
                .font(DesignSystem.fonts.body(size: 13))
                .foregroundColor(DesignSystem.colors.blueGrey)

              Text(session.status.uppercased())
                .font(DesignSystem.fonts.mono(size: 12, weight: .semibold))
                .foregroundColor(session.status.lowercased().contains("local") ? .orange : DesignSystem.colors.deepGreen)
            }
            .brutalistCard(stroke: DesignSystem.colors.blueGrey)
          }
        }
      }
      .padding(14)
    }
    .background(DesignSystem.colors.deepNavy)
  }
}
