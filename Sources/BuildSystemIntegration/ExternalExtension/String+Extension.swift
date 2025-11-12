//
//  File.swift
//  SwiftBuild
//
//  Created by ByteDance on 23/04/2025.
//

import Foundation

extension String {
  func capitalizingFirstLetter() -> String {
    return prefix(1).capitalized + dropFirst()
  }

  func deletingPrefix(_ prefix: String) -> String {
    guard hasPrefix(prefix) else { return self }
    return String(dropFirst(prefix.count))
  }

  func deletingSuffix(_ suffix: String) -> String {
    guard hasSuffix(suffix) else { return self }
    return String(dropLast(suffix.count))
  }

  func substringBefore(_ marker: String.Element) -> String {
    guard let index = firstIndex(of: marker) else { return self }
    return String(self[..<index])
  }

  func indent() -> String {
    "    " + replacingOccurrences(of: "\n", with: "\n    ")
  }

  enum TrimmingOptions {
    case all
    case leading
    case trailing
    case leadingAndTrailing
  }

  func trimming(spaces: TrimmingOptions, using characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
    switch spaces {
    case .all: return trimmingAllSpaces(using: characterSet)
    case .leading: return trimmingLeadingSpaces(using: characterSet)
    case .trailing: return trimmingTrailingSpaces(using: characterSet)
    case .leadingAndTrailing: return trimmingLeadingAndTrailingSpaces(using: characterSet)
    }
  }

  private func trimmingLeadingSpaces(using characterSet: CharacterSet) -> String {
    guard let index = firstIndex(where: { !CharacterSet(charactersIn: String($0)).isSubset(of: characterSet) }) else {
      return self
    }

    return String(self[index...])
  }

  private func trimmingTrailingSpaces(using characterSet: CharacterSet) -> String {
    guard let index = lastIndex(where: { !CharacterSet(charactersIn: String($0)).isSubset(of: characterSet) }) else {
      return self
    }

    return String(self[...index])
  }

  private func trimmingLeadingAndTrailingSpaces(using characterSet: CharacterSet) -> String {
    return trimmingCharacters(in: characterSet)
  }

  private func trimmingAllSpaces(using characterSet: CharacterSet) -> String {
    return components(separatedBy: characterSet).joined()
  }

  var exportEnvQuoted: String {
    guard rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return self }
    return #""\#(self)""#
  }

  public var resolveSymlink: String {
    let url = URL(fileURLWithPath: self)
    return url.resolvingSymlinksInPath().path
  }

  public var pathExtension: String {
    return (self as NSString).pathExtension
  }

  public var deletingPathExtension: String {
    return (self as NSString).deletingPathExtension
  }

  var deletingLastPathComponent: String {
    return (self as NSString).deletingLastPathComponent
  }

  var pathComponents: [String] {
    return (self as NSString).pathComponents
  }

  var filename: String {
    return (self as NSString).lastPathComponent
  }

  var url: URL {
    return URL(fileURLWithPath: self)
  }

  var languageDialect: String? {
    if hasSuffix(".m") {
      return "objective-c"
    } else if hasSuffix(".mm") {
      return "objective-c++"
    } else if hasSuffix(".cpp") || hasSuffix(".cc") {
      return "c++"
    } else if hasSuffix(".c") {
      return "c"
    } else if hasSuffix(".swift") {
      return "swift"
    }
    return nil
  }

  var basename: String {
    return (self as NSString).lastPathComponent
  }

  var exists: Bool {
    return FileManager.default.fileExists(atPath: self)
  }

  var standardizingPath: String {
    return (self as NSString).standardizingPath
  }

  var isDirectory: Bool {
    var directory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: self, isDirectory: &directory) else {
      return false
    }
    return directory.boolValue
  }

  public var isSymlink: Bool {
    do {
      _ = try FileManager.default.destinationOfSymbolicLink(atPath: self)
      return true
    } catch {
      return false
    }
  }

  func delete() throws {
    try FileManager.default.removeItem(atPath: self)
  }

  func mkpath() throws {
    try FileManager.default.createDirectory(atPath: standardizingPath, withIntermediateDirectories: true, attributes: nil)
  }

  func appendingPathComponent(component: String) -> String {
    if hasSuffix("/") {
      return self + component
    } else {
      return self + "/" + component
    }
  }
}
