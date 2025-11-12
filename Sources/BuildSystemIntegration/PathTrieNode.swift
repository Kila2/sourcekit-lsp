//
//  PathTrieNode.swift
//  SourceKitLSP
//
//  Created by ByteDance on 11/12/25.
//

import Foundation
internal import LanguageServerProtocol

/// A node in the PathTrie. Each node represents a path component.
class PathTrieNode {
  /// The children of this node, keyed by the next path component.
  var children: [String: PathTrieNode] = [:]
  
  /// A dictionary of representative compile commands for this directory,
  /// keyed by file extension (e.g., "swift", "c", "m", "mm").
  /// This is crucial for mixed-language projects.
  var commandsByExtension: [String: CompilationDatabaseCompileCommand] = [:]
}

/// A Trie data structure that supports mixed-language projects by indexing
/// commands based on file extension.
class PathTrie {
  private let root = PathTrieNode()
  
  /// Inserts a compile command into the trie.
  /// It uses the file's extension to store the command, allowing different
  /// commands for different languages in the same directory.
  func insert(command: CompilationDatabaseCompileCommand) {
    guard let url = command.uri.fileURL else {
      return
    }
    
    // Get the file extension to identify the language.
    let fileExtension = url.pathExtension
    if fileExtension.isEmpty {
      return // Cannot handle files without an extension.
    }
    
    let directoryURL = url.deletingLastPathComponent()
    let components = directoryURL.pathComponents.filter { $0 != "/" }
    
    var currentNode = root
    for component in components {
      if let child = currentNode.children[component] {
        currentNode = child
      } else {
        let newNode = PathTrieNode()
        currentNode.children[component] = newNode
        currentNode = newNode
      }
    }
    
    // Store the command for this specific file type if one isn't already present.
    if currentNode.commandsByExtension[fileExtension] == nil {
      currentNode.commandsByExtension[fileExtension] = command
    }
  }
  
  /// Finds the compile command from the nearest ancestor directory for a given
  /// document URI and its file extension.
  ///
  /// - Parameters:
  ///   - uri: The URI of the file to find a command for.
  ///   - fileExtension: The extension of the file (e.g., "swift", "c").
  /// - Returns: The `CompileCommand` for the corresponding file type from the
  ///   closest parent directory, or `nil`.
  func findCommand(for uri: DocumentURI, fileExtension: String) -> CompilationDatabaseCompileCommand? {
    guard let url = uri.fileURL else {
      return nil
    }
    
    let pathComponents = url.pathComponents.filter { $0 != "/" }
    let componentsToSearch = url.hasDirectoryPath ? pathComponents : pathComponents.dropLast()
    
    var currentNode = root
    // The root could potentially have a command for a file in "/"
    var lastFoundCommand: CompilationDatabaseCompileCommand? = root.commandsByExtension[fileExtension]
    
    for component in componentsToSearch {
      guard let child = currentNode.children[component] else {
        return lastFoundCommand
      }
      currentNode = child
      // If this directory has a command for our specific file type, update our best guess.
      if let command = currentNode.commandsByExtension[fileExtension] {
        lastFoundCommand = command
      }
    }
    
    return lastFoundCommand
  }
}
