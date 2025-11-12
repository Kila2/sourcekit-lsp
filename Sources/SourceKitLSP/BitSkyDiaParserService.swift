//
//  DiaParserService.swift
//  SourceKitLSP
//
//  Created by ByteDance on 6/27/25.
//

// file: BitSkyDiaParserService.swift

import Foundation
package import LanguageServerProtocol
import SKLogging
import TSCBasic
import TSCUtility

public struct BitSkyDiaParserService: Sendable {
  private let fileSystem: FileSystem
  
  init(fileSystem: FileSystem = localFileSystem) {
    self.fileSystem = fileSystem
  }
  
  /// 解析指定的 .dia 文件，并返回一个按文件 URI 分组的诊断字典。
  /// - Parameter diaFileUri: .dia 文件的 URI。
  /// - Returns: 一个字典，键是源文件的 URI，值是该文件的诊断数组。
  func parse(diaFileUri: DocumentURI) async throws -> [DocumentURI: [LanguageServerProtocol.Diagnostic]] {
    guard let diaFilePath = diaFileUri.fileURL else {
      throw ResponseError(code: .invalidParams, message: "Invalid URI for diagnostics file: \(diaFileUri)")
    }
    
    let diaFileContents = try fileSystem.readFileContents(AbsolutePath(validating: diaFilePath.path))
    
    let serializedDiags = try SerializedDiagnostics(bytes: diaFileContents)
    
    var diagnosticsByFile: [DocumentURI: [LanguageServerProtocol.Diagnostic]] = [:]
    
    guard let workingDir = diaFilePath.path.split(separator: "bazel-out").first else {
      return [:]
    }
    
    for diag in serializedDiags.diagnostics {
      
      guard let location = diag.location else {
        continue
      }
      let sourceFileUri = if location.filename.starts(with: "/") {
        createDocumentURI(from: location.filename)
      } else {
        createDocumentURI(from: "\(workingDir)\(location.filename)")
      }
      guard let sourceFileUri = sourceFileUri else {
        continue
      }
      if let lspDiag = self.toLSPDiagnostic(diag) {
        diagnosticsByFile[sourceFileUri, default: []].append(lspDiag)
      }
    }
    
    return diagnosticsByFile
  }
  
  private func toLSPDiagnostic(_ diag: SerializedDiagnostics.Diagnostic) -> LanguageServerProtocol.Diagnostic? {
    let severity: DiagnosticSeverity
    switch diag.level {
    case .error, .fatal:
      severity = .error
    case .warning:
      severity = .warning
    case .note:
      severity = .information
    case .remark:
      severity = .hint
    case .ignored:
      return nil
    }
    
    guard let location = diag.location else {
      return nil
    }
    
    let startPosition = Position(line: Int(location.line) - 1, utf16index: Int(location.column) - 1)
    var lspRange = Range(startPosition)
    
    if let firstRange = diag.ranges.first {
      let lowerBound = Position(line: Int(firstRange.0.line) - 1, utf16index: Int(firstRange.0.column) - 1)
      let upperBound = Position(line: Int(firstRange.1.line) - 1, utf16index: Int(firstRange.1.column) - 1)
      lspRange = Range<Position>.init(uncheckedBounds: (lower: lowerBound, upper: upperBound))
    }
    
    return LanguageServerProtocol.Diagnostic(
      range: lspRange,
      severity: severity,
      code: nil,
      source: diag.category ?? (isSwift(diag.location?.filename) ? "swiftc" : "clang"),
      message: diag.text,
      tags: nil,
      relatedInformation: nil
    )
  }
  
  private func createDocumentURI(from path: String) -> DocumentURI? { // **修正 1**
    guard !path.isEmpty else { return nil }
    if let absolutePath = try? AbsolutePath(validating: path) {
      return DocumentURI(absolutePath.asURL)
    } else {
      logger.error("Received a relative path in diagnostics which is not supported: \(path)")
      return nil
    }
  }
  
  private func isSwift(_ filename: String?) -> Bool {
    return filename?.hasSuffix(".swift") ?? false
  }
}

extension SourceKitLSPServer {
  // 新增：为我们的自定义请求实现处理函数
  public func parseDiagnosticsFile(_ req: ParseDiagnosticsFileRequest) async throws -> VoidResponse {
    // 1. 调用独立的服务来解析文件
    let diagnosticsByFile = try await diaParserService.parse(diaFileUri: req.textDocument.uri)
    
    // 2. 遍历解析结果，并为每个文件发布诊断
    for (fileUri, diagnostics) in diagnosticsByFile {
      await publishDiagnostics(for: fileUri, diagnostics: diagnostics)
    }
    
    // 3. 如果 .dia 文件中提到的某些文件没有诊断信息（例如，错误被修复了），
    // 我们可能需要为这些文件发布一个空的诊断数组来清空旧的错误。
    // 这需要更复杂的逻辑来跟踪哪些文件曾被该 .dia 文件影响，为简化起见此处省略。
    
    return VoidResponse()
  }
  
  public func parseDiagnosticsFiles(_ req: ParseDiagnosticsFilesRequest) async throws -> VoidResponse {
    for textDocument in req.textDocuments {
      // 1. 调用独立的服务来解析文件
      let diagnosticsByFile = try await diaParserService.parse(diaFileUri: textDocument.uri)
      
      // 2. 遍历解析结果，并为每个文件发布诊断
      for (fileUri, diagnostics) in diagnosticsByFile {
        await publishDiagnostics(for: fileUri, diagnostics: diagnostics)
      }
    }
    // 3. 如果 .dia 文件中提到的某些文件没有诊断信息（例如，错误被修复了），
    // 我们可能需要为这些文件发布一个空的诊断数组来清空旧的错误。
    // 这需要更复杂的逻辑来跟踪哪些文件曾被该 .dia 文件影响，为简化起见此处省略。
    
    return VoidResponse()
  }
  
  // 辅助方法：发布诊断（可以复用之前的代码）
  private func publishDiagnostics(for uri: DocumentURI, diagnostics: [LanguageServerProtocol.Diagnostic]) async {
    // 尝试获取文档的当前版本号，如果文档是打开的
    let version = try? self.documentManager.latestSnapshot(uri).version
    
    self.sendNotificationToClient(
      PublishDiagnosticsNotification(
        uri: uri,
        version: version, // 如果文档未打开，版本号为 nil，这是允许的
        diagnostics: diagnostics
      )
    )
  }
}
