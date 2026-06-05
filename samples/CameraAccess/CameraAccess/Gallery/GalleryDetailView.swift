import SwiftUI

struct GalleryDetailView: View {
  let photo: CapturedPhoto
  @ObservedObject private var store = PhotoCaptureStore.shared
  @Environment(\.dismiss) private var dismiss
  @State private var showShareSheet = false
  @State private var showDeleteConfirmation = false

  private var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: photo.timestamp)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Image
      if let image = store.imageForPhoto(photo) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: .infinity)

        // Metadata
        VStack(alignment: .leading, spacing: 8) {
          Text(formattedDate)
            .font(.subheadline)
            .foregroundColor(.secondary)

          if let description = photo.description, !description.isEmpty {
            Text(description)
              .font(.body)
              .foregroundColor(.primary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

        Spacer()

        // Actions
        HStack(spacing: 40) {
          Button(action: { showShareSheet = true }) {
            VStack(spacing: 4) {
              Image(systemName: "square.and.arrow.up")
                .font(.title2)
              Text("Share")
                .font(.caption)
            }
          }

          Button(role: .destructive, action: { showDeleteConfirmation = true }) {
            VStack(spacing: 4) {
              Image(systemName: "trash")
                .font(.title2)
              Text("Delete")
                .font(.caption)
            }
          }
        }
        .padding(.bottom, 30)

        .sheet(isPresented: $showShareSheet) {
          ShareSheet(photo: image)
        }
      } else {
        Text("Photo not found")
          .foregroundColor(.secondary)
          .padding()
        Spacer()
      }
    }
    .navigationTitle("Photo")
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirmation) {
      Button("Delete", role: .destructive) {
        store.deletePhoto(photo)
        dismiss()
      }
      Button("Cancel", role: .cancel) {}
    }
  }
}
