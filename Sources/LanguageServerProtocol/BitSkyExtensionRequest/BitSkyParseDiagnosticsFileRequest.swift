//
//  ParseDiagnosticsFileParams.swift
//  SourceKitLSP
//
//  Created by ByteDance on 6/27/25.
//

public struct ParseDiagnosticsFileRequest: TextDocumentRequest {
  public static let method: String = "workspace/parseDiagnosticsFile"
  public typealias Response = VoidResponse
  
  /// The document to request code lens for.
  public var textDocument: TextDocumentIdentifier
  
  public init(textDocument: TextDocumentIdentifier) {
    self.textDocument = textDocument
  }
  
  enum CodingKeys: CodingKey {
    case textDocument
  }
  
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.textDocument = try container.decode(TextDocumentIdentifier.self, forKey: .textDocument)
  }
}

public struct ParseDiagnosticsFilesRequest: RequestType {
  public static let method: String = "workspace/parseDiagnosticsFiles"
  public typealias Response = VoidResponse
  
  /// The document to request code lens for.
  public var textDocuments: [TextDocumentIdentifier]
  
  public init(textDocuments: [TextDocumentIdentifier]) {
    self.textDocuments = textDocuments
  }
  
  enum CodingKeys: CodingKey {
    case textDocuments
  }
  
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.textDocuments = try container.decode([TextDocumentIdentifier].self, forKey: .textDocuments)
  }
}
