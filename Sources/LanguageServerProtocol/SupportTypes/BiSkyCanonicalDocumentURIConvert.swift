//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if compiler(>=6)
public import Foundation
#else
import Foundation
#endif

public actor CanonicalDocumentURIConvert {
  public static let shared = CanonicalDocumentURIConvert()
  
  nonisolated(unsafe) private static var staticSourceMapInfo: [String: String] = [:]
  nonisolated(unsafe) private static var staticWorkspacePath: String!
  nonisolated(unsafe) private static var staticOutputBase: String!
  nonisolated(unsafe) private static var staticExecutionRoot: String!
  nonisolated(unsafe) private static var staticSourceKitLSPOptionsConfigURL: URL!
  nonisolated(unsafe) private static var staticEnabledUniqBazelServer: Bool = false
  nonisolated(unsafe) private static var staticIndexStorePath: String!

  public func preload(workspacePath: String, outputBase: String, executionRoot: String, filePath: String, sourceKitLSPOptionsConfigURL: URL) {
    Self.staticWorkspacePath = workspacePath
    Self.staticOutputBase = outputBase
    Self.staticExecutionRoot = executionRoot
    let info = loadSourceMapInfo(filePath: filePath)
    Self.staticSourceMapInfo = info // 👈 缓存到全局 static 变量
    loadBitSkyInfo(sourceKitLSPOptionsConfigURL: sourceKitLSPOptionsConfigURL)
    Self.staticSourceKitLSPOptionsConfigURL = sourceKitLSPOptionsConfigURL;
  }
  
  nonisolated public func getSourceMapInfo() -> [String: String] {
    return Self.staticSourceMapInfo
  }
  
  nonisolated public func getWorkspacePath() -> String {
    return Self.staticWorkspacePath
  }
  
  nonisolated public func getOutputBase() -> String {
    return Self.staticOutputBase
  }
  
  nonisolated public func getExecutionRoot() -> String {
    return Self.staticExecutionRoot
  }
  
  nonisolated public func getUniqBazelServerOption() -> Bool {
    return Self.staticEnabledUniqBazelServer
  }
  
  nonisolated public func getIndexStorePath() -> String {
    return Self.staticIndexStorePath
  }

  private func loadSourceMapInfo(filePath: String) -> [String: String] {
    let sourceMapInfoURL = URL(fileURLWithPath: filePath)
    if FileManager.default.fileExists(atPath: sourceMapInfoURL.path) {
      if let content = try? String(contentsOf: sourceMapInfoURL, encoding: .utf8) {
        return (try? JSONDecoder().decode([String: String].self, from: Data(content.utf8))) ?? [:]
      }
    }
    return [:]
  }
  
  private func loadBitSkyInfo(sourceKitLSPOptionsConfigURL: URL) {
    do {
      let data = try Data(contentsOf: sourceKitLSPOptionsConfigURL)
      let jsonObject = try JSONSerialization.jsonObject(with: data)
      if let jsonObject = jsonObject as? Dictionary<String, Any> {
        if let bitskyOptionsObject = jsonObject["bitsky"] as? Dictionary<String, Any> {
          if let enabledUniqBazelServer = bitskyOptionsObject["enabledUniqBazelServer"] as? Bool {
            Self.staticEnabledUniqBazelServer = enabledUniqBazelServer
          }
        }
        if let bitskyOptionsObject = jsonObject["index"] as? Dictionary<String, Any> {
          if let indexStorePath = bitskyOptionsObject["indexStorePath"] as? String {
            Self.staticIndexStorePath = indexStorePath
          }
        }
      }
    } catch {
      
    }
  }
}
