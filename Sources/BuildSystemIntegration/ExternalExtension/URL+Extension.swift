//
//  URL+Extension.swift
//  SwiftBuild
//
//  Created by ByteDance on 2025/4/24.
//
public import Foundation

enum FileError: Error {
  case fileDoesNotExist(path: URL)
  case missingModificationDate
}

extension FileError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .fileDoesNotExist(let path):
      return "The file does not exist at path: \(path.path)"
    case .missingModificationDate:
      return "The file is missing its modification date attribute."
    }
  }
}

extension URL {
  public func modifyTimeIntervalSince1970() throws -> TimeInterval {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: path) else {
      throw FileError.fileDoesNotExist(path: self)
    }
    let attributes = try fileManager.attributesOfItem(atPath: path)
    guard let modificationDate = attributes[.modificationDate] as? Date else {
      throw FileError.missingModificationDate
    }
    return modificationDate.timeIntervalSince1970
  }
  
  public var pathString: String {
    if #available(macOS 13.0, *) {
      return self.path()
    } else {
      return path
    }
  }
}
