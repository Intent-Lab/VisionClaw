import SwiftUI

struct GalleryView: View {
  @ObservedObject private var store = PhotoCaptureStore.shared
  @State private var selectedPhoto: CapturedPhoto?

  private let columns = [
    GridItem(.flexible(), spacing: 2),
    GridItem(.flexible(), spacing: 2),
    GridItem(.flexible(), spacing: 2),
  ]

  var body: some View {
    Group {
      if store.photos.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 48))
            .foregroundColor(.secondary)
          Text("No captured photos yet")
            .font(.headline)
            .foregroundColor(.secondary)
          Text("Ask the AI to take a photo while using the glasses")
            .font(.subheadline)
            .foregroundColor(.secondary.opacity(0.7))
            .multilineTextAlignment(.center)
        }
        .padding()
      } else {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 2) {
            ForEach(store.photos) { photo in
              GalleryThumbnail(photo: photo)
                .onTapGesture {
                  selectedPhoto = photo
                }
            }
          }
        }
      }
    }
    .navigationTitle("Gallery")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $selectedPhoto) { photo in
      NavigationStack {
        GalleryDetailView(photo: photo)
      }
    }
  }
}

private struct GalleryThumbnail: View {
  let photo: CapturedPhoto
  @ObservedObject private var store = PhotoCaptureStore.shared

  var body: some View {
    GeometryReader { geo in
      if let image = store.imageForPhoto(photo) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: geo.size.width, height: geo.size.width)
          .clipped()
      } else {
        Color.gray.opacity(0.3)
          .frame(width: geo.size.width, height: geo.size.width)
      }
    }
    .aspectRatio(1, contentMode: .fit)
  }
}
