//
//  WorkspaceSymbolTreeRequest.swift
//  SourceKitLSP
//
//  Created by ByteDance on 9/24/25.
//


public struct WorkspaceSymbolTreeRequest: RequestType, Encodable {
  public static let method: String = "workspace/symbolTree"
  public typealias Response = [SymbolNode]
  
  /// The root URI of the workspace/project to analyze.
  public var workspaceUri: DocumentURI
  
  /// Optional. A relative path within the workspace to filter results.
  public var relativePathFilter: String?
  
  /// Optional. Whether to include the body of the symbols. Defaults to false.
  /// NOTE: IndexStoreDB does not store symbol bodies. This would require file reads.
  /// We will ignore this parameter in our DB-only implementation.
  public var includeBody: Bool
  
  init(workspaceUri: DocumentURI, relativePathFilter: String?, includeBody: Bool) {
    self.workspaceUri = workspaceUri
    self.relativePathFilter = relativePathFilter
    self.includeBody = includeBody
  }
  
  enum CodingKeys: CodingKey {
    case workspaceUri
    case relativePathFilter
    case includeBody
  }
  
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.workspaceUri = try container.decode(DocumentURI.self, forKey: .workspaceUri)
    self.relativePathFilter = try container.decode(String?.self, forKey: .relativePathFilter)
    self.includeBody = try container.decode(Bool.self, forKey: .includeBody)
  }
}

// 这个结构是递归的，并且必须是 Codable 以便 JSON 序列化。
public struct SymbolNode: ResponseType, Codable, Hashable {
  public var name: String
  public var kind: SymbolKind
  @CustomCodable<PositionRange>
  public var range: Range<Position>
  @CustomCodable<PositionRange>
  public var selectionRange: Range<Position>
  public var location: Location
  public var children: [SymbolNode]?
  
  // Note: 'parent' is intentionally omitted to prevent circular references in JSON.
  public init(name: String, kind: SymbolKind, range: Range<Position>, selectionRange: Range<Position>, location: Location, children: [SymbolNode]? = nil) {
    self.name = name
    self.kind = kind
    self._range = CustomCodable<PositionRange>(wrappedValue: range)
    self._selectionRange = CustomCodable<PositionRange>(wrappedValue: selectionRange)
    self.location = location
    self.children = children
  }
}
