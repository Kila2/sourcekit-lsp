//
//  BitSkyWorkspaceSymbolTreeBuilder.swift
//  SourceKitLSP
//
//  Created by ByteDance on 9/24/25.
//


import Foundation
import LanguageServerProtocol
import SemanticIndex
import IndexStoreDB

// A global constant for zero range, useful for directory/file nodes.
fileprivate let zeroRange = Range(Position(line: 0, utf16index: 0))

extension SourceKitLSPServer {
  
  func handleWorkspaceSymbolTree(_ req: WorkspaceSymbolTreeRequest) throws -> [SymbolNode] {
    guard let workspace = workspaces.first(where: {$0.rootUri == req.workspaceUri}) else {
      return []
    }
    
    guard let index = workspace.index(checkedFor: .deletedFiles) else {
      return []
    }
    
    // Use a dedicated builder struct to encapsulate the complex tree-building logic.
    let builder = SymbolTreeBuilder(
      index: index,
      workspaceUri: req.workspaceUri,
      relativePathFilter: req.relativePathFilter,
      directoryNodeCache: [:]
    )
    
    return builder.build()
  }
}


// MARK: - SymbolTreeBuilder

/// Encapsulates the logic to build a directory-based symbol tree from IndexStoreDB.
public struct SymbolTreeBuilder {
  let index: CheckedIndex
  let workspaceUri: DocumentURI
  let relativePathFilter: String?
  
  // A dictionary to keep track of directory nodes we've created, keyed by their URI.
  // This is crucial for efficiently building the tree.
  private var directoryNodeCache: [DocumentURI: SymbolNode] = [:]
  
  internal init(index: CheckedIndex, workspaceUri: DocumentURI, relativePathFilter: String?, directoryNodeCache: [DocumentURI : SymbolNode]) {
    self.index = index
    self.workspaceUri = workspaceUri
    self.relativePathFilter = relativePathFilter
    self.directoryNodeCache = directoryNodeCache
  }
  
  private class MutableSymbolNode {
    var symbol: SymbolNode
    var childrenMap: [String: MutableSymbolNode] = [:] // For quick child lookup by name
    
    init(_ symbol: SymbolNode) {
      self.symbol = symbol
    }
  }
  
  func build() -> [SymbolNode] {
    index.unchecked.pollForUnitChangesAndWait()
    // --- STEP 1: Discover all unique source file paths from the index ---
    var allFilePaths = Set<String>()
    index.forEachCanonicalSymbolOccurrence(
      containing: "",
      anchorStart: false,
      anchorEnd: false,
      subsequence: false,
      ignoreCase: false
    ) { occurrence in
      if !occurrence.location.path.contains("bazel-out"), let filter = self.relativePathFilter, !filter.isEmpty, !occurrence.location.path.contains(filter) {
        return true
      }
      // Ensure we only process files that are descendants of the workspace root.
      // This is a crucial step to avoid dealing with external or strange paths.
      if let workspacePath = workspaceUri.fileURL?.path, occurrence.location.path.starts(with: workspacePath) {
        allFilePaths.insert(occurrence.location.path)
      }
      return true
    }
    
    // --- STEP 2: Build the tree structure iteratively ---
    let rootSymbol = createDirectoryNode(for: workspaceUri)
    let rootNode = MutableSymbolNode(rootSymbol)
    
    for path in allFilePaths {
      let fileURL = URL(fileURLWithPath: path)
      
      // Get path components relative to the workspace root.
      guard let workspacePath = workspaceUri.fileURL?.path,
            path.starts(with: workspacePath) else {
        continue
      }
      
      // Decompose path into components, e.g., ["Sources", "Subfolder", "MyFile.swift"]
      let relativePath = String(path.dropFirst(workspacePath.count))
      let components = relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
      
      var currentNode = rootNode
      var currentPath = workspaceUri.fileURL!
      
      // Traverse or create directory nodes for each component.
      for component in components.dropLast() { // Iterate through directories only
        currentPath.appendPathComponent(component)
        
        if let existingChild = currentNode.childrenMap[component] {
          currentNode = existingChild
        } else {
          // Create a new directory node
          let newDirUri = DocumentURI(currentPath)
          let newDirSymbol = createDirectoryNode(for: newDirUri)
          let newNode = MutableSymbolNode(newDirSymbol)
          
          currentNode.childrenMap[component] = newNode
          currentNode = newNode
        }
      }
      
      // Finally, create and add the file node.
      if let fileName = components.last {
        if currentNode.childrenMap[fileName] == nil {
          if let fileNodeSymbol = createFileNodeWithSymbols(for: DocumentURI(fileURL), in: path) {
            let fileMutableNode = MutableSymbolNode(fileNodeSymbol)
            currentNode.childrenMap[fileName] = fileMutableNode
          }
        }
      }
    }
    
    // --- STEP 3: Convert the mutable tree back to the required SymbolNode struct array ---
    return convertToSymbolNodeTree(from: rootNode).children ?? []
  }
  
  /// Recursively converts our internal MutableSymbolNode tree to the final SymbolNode struct tree.
  private func convertToSymbolNodeTree(from mutableNode: MutableSymbolNode) -> SymbolNode {
    var finalSymbol = mutableNode.symbol
    if !mutableNode.childrenMap.isEmpty {
      // Sort children by name for a stable order.
      finalSymbol.children = mutableNode.childrenMap.values
        .map { convertToSymbolNodeTree(from: $0) }
        .sorted { $0.name < $1.name }
    }
    return finalSymbol
  }
  
  // --- Tree Building Helpers ---
  
  /// Recursively finds or creates directory nodes for a given file URI.
  private func getOrCreateParentDirectoryNode(for fileUri: DocumentURI, cache: inout [DocumentURI: SymbolNode]) -> SymbolNode {
    guard let fileURL = fileUri.fileURL else {
      return cache[workspaceUri]! // Should not happen
    }
    
    let parentDirURL = fileURL.deletingLastPathComponent()
    
    if parentDirURL == fileURL || parentDirURL.path.isEmpty {
      // We've gone past the workspace root. Stop recursion and return the root node.
      return cache[workspaceUri]!
    }
    
    let parentDirUri = DocumentURI(parentDirURL)
    
    // If the parent is the workspace root, we're done.
    if parentDirUri == workspaceUri {
      return cache[workspaceUri]!
    }
    
    // If the parent directory is already in our cache, return it.
    if let cachedNode = cache[parentDirUri] {
      return cachedNode
    }
    
    // The parent is not in the cache, so we need to create it and its own parents recursively.
    let grandParentNode = getOrCreateParentDirectoryNode(for: parentDirUri, cache: &cache)
    
    let newDirNode = createDirectoryNode(for: parentDirUri)
    cache[parentDirUri] = newDirNode
    
    // Link the new directory to its grandparent.
    if var mutableGrandParent = cache[grandParentNode.location.uri] {
      if mutableGrandParent.children == nil {
        mutableGrandParent.children = []
      }
      mutableGrandParent.children?.append(newDirNode)
      cache[grandParentNode.location.uri] = mutableGrandParent
    }
    
    return newDirNode
  }
  
  /// Assembles the final tree from the flat cache of directory nodes.
  private func assembleTree(from cache: [DocumentURI: SymbolNode]) -> [SymbolNode] {
    var finalNodes = cache
    var childUris = Set<DocumentURI>()
    
    // Identify all nodes that are children of other nodes.
    for node in finalNodes.values {
      if let children = node.children {
        for child in children {
          childUris.insert(child.location.uri)
        }
      }
    }
    
    // The root nodes are those that are not in the childUris set, excluding the workspace root itself.
    var rootNodes: [SymbolNode] = []
    if let workspaceNode = finalNodes[workspaceUri] {
      rootNodes = workspaceNode.children ?? []
    }
    
    // Sort the final nodes for a consistent output.
    return rootNodes.sorted { $0.name < $1.name }
  }
  
  
  // --- Node Creation Helpers ---
  
  /// Creates a SymbolNode representing a directory (Package).
  private func createDirectoryNode(for uri: DocumentURI) -> SymbolNode {
    let name = (uri.fileURL?.lastPathComponent).flatMap { $0.isEmpty ? workspaceUri.fileURL?.lastPathComponent : $0 } ?? "Unknown"
    return SymbolNode(
      name: name,
      kind: .package,
      range: zeroRange,
      selectionRange: zeroRange,
      location: Location(uri: uri, range: zeroRange),
      children: [] // Start with empty children
    )
  }
  
  /// Creates a SymbolNode for a file and populates its children with symbols from the index.
  private func createFileNodeWithSymbols(for uri: DocumentURI, in path: String) -> SymbolNode? {
    let occurrencesInFile = index.symbolOccurrences(inFilePath: path)
    guard !occurrencesInFile.isEmpty else {
      return nil
    }
    
    var fileNode = SymbolNode(
      name: uri.fileURL?.lastPathComponent ?? "Unknown File",
      kind: .file,
      range: zeroRange,
      selectionRange: zeroRange,
      location: Location(uri: uri, range: zeroRange),
      children: []
    )
    
    var children: [SymbolNode] = []
    for occurrence in occurrencesInFile {
      if occurrence.roles.contains(.definition) {
        children.append(createSymbolNode(from: occurrence, in: uri))
      }
    }
    
    if !children.isEmpty {
      fileNode.children = children.sorted(by: {$0.location < $1.location})
    }
    
    return fileNode
  }
  
  /// Creates a leaf SymbolNode from a SymbolOccurrence.
  private func createSymbolNode(from occurrence: SymbolOccurrence, in fileUri: DocumentURI) -> SymbolNode {
    let location = occurrence.location
    let startPosition = Position(
      line: location.line > 0 ? location.line - 1 : 0,
      utf16index: location.utf8Column > 0 ? location.utf8Column - 1 : 0
    )
    let range = Range(startPosition)
    
    return SymbolNode(
      name: occurrence.symbol.name,
      kind: mapSymbolKind(occurrence.symbol.kind),
      range: range,
      selectionRange: range,
      location: Location(uri: fileUri, range: range),
      children: nil
    )
  }
  
  private func mapSymbolKind(_ indexKind: IndexSymbolKind) -> SymbolKind {
    switch indexKind {
    case .unknown: return .null
    case .module: return .module
    case .namespace, .namespaceAlias: return .namespace
    case .macro: return .string
    case .enum: return .enum
    case .struct: return .struct
    case .class: return .class
    case .protocol: return .interface
    case .extension: return .namespace
    case .union: return .struct
    case .typealias: return .typeParameter
    case .function: return .function
    case .variable, .field: return .variable
    case .enumConstant: return .enumMember
    case .instanceMethod, .classMethod, .staticMethod: return .method
    case .instanceProperty, .classProperty, .staticProperty: return .property
    case .constructor: return .constructor
    case .destructor: return .method
    case .conversionFunction: return .function
    case .parameter: return .variable
    case .using: return .namespace
    case .concept: return .interface
    case .commentTag: return .string
    }
  }
}
