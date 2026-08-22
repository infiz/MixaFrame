import Foundation

enum MacMediaImportService {
  @MainActor
  static func importPhotos(from urls: [URL], using store: AppStore) async -> [CollagePhoto] {
    var imported: [CollagePhoto] = []
    for url in urls.prefix(12) {
      let hasSecurityScope = url.startAccessingSecurityScopedResource()
      defer {
        if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
      }
      do {
        imported.append(try await store.importPhotoFile(at: url))
      } catch {
        store.alertMessage = error.localizedDescription
      }
    }
    return imported
  }
}
