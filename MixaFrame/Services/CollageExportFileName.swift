import Foundation

enum CollageExportFileName {
  static func make(
    collectionName: String,
    projectName: String,
    format: OutputFormat,
    date: Date = Date(),
    timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let timestamp = formatter.string(from: date)
    return [
      timestamp,
      sanitizedComponent(collectionName, fallback: "Collection"),
      sanitizedComponent(projectName, fallback: "Project"),
    ].joined(separator: "-") + "." + format.fileExtension
  }

  private static func sanitizedComponent(_ value: String, fallback: String) -> String {
    let normalized = value.precomposedStringWithCanonicalMapping
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    var result = ""

    for character in normalized {
      let isAllowed = character.unicodeScalars.allSatisfy { allowed.contains($0) }
      if isAllowed {
        if character == "-", result.last == "-" { continue }
        result.append(character)
      } else if !result.isEmpty, result.last != "-" {
        result.append("-")
      }
    }

    let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    guard !trimmed.isEmpty else { return fallback }

    let maximumUTF8Bytes = 80
    var safeName = ""
    var byteCount = 0
    for character in trimmed {
      let characterBytes = String(character).utf8.count
      guard byteCount + characterBytes <= maximumUTF8Bytes else { break }
      safeName.append(character)
      byteCount += characterBytes
    }
    safeName = safeName.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return safeName.isEmpty ? fallback : safeName
  }
}
