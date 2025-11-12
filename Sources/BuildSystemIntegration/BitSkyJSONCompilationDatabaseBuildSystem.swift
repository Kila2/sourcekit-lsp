//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

package import BuildServerProtocol
package import Foundation
package import LanguageServerProtocol
import SKLogging
import SwiftExtensions
package import ToolchainRegistry

fileprivate extension CompilationDatabaseCompileCommand {
  /// The first entry in the command line identifies the compiler that should be used to compile the file and can thus
  /// be used to infer the toolchain.
  ///
  /// Note that this compiler does not necessarily need to exist on disk. Eg. tools may just use `clang` as the compiler
  /// without specifying a path.
  ///
  /// The absence of a compiler means we have an empty command line, which should never happen.
  ///
  /// If the compiler is a symlink to `swiftly`, it uses `swiftlyResolver` to find the corresponding executable in a
  /// real toolchain and returns that executable.
  func compiler(swiftlyResolver: SwiftlyResolver) async -> String? {
    guard let compiler = commandLine.first else {
      return nil
    }
    let swiftlyResolved = await orLog("Resolving swiftly") {
      try await swiftlyResolver.resolve(
        compiler: URL(fileURLWithPath: compiler),
        workingDirectory: URL(fileURLWithPath: directory)
      )?.filePath
    }
    if let swiftlyResolved {
      return swiftlyResolved
    }
    return compiler
  }
}

/// A `BuildSystem` that provides compiler arguments from a `compile_commands.json` file.
package actor BitSkyJSONCompilationDatabaseBuildSystem: BuiltInBuildSystem {
  package static let dbName: String = "compile_commands.json"

  /// The compilation database.
  var compdbTask: Task<BitSkyCompilationDatabase?, Error>? = nil {
    didSet {
      // Build settings have changed and thus the index store path might have changed.
      // Recompute it on demand.
      self.commandTrie = nil
      self.commandsByCompiler = nil
      _indexStorePath.reset()
    }
  }

  /// A trie of compile commands, used to find fallback commands for new files.
  /// This is built lazily on first access.
  private var commandTrie: PathTrie?

  /// A cache of compile commands grouped by their compiler executable path.
  /// This is built lazily to optimize `buildTargetSources`.
  private var commandsByCompiler: [String: [CompilationDatabaseCompileCommand]]?

  private let toolchainRegistry: ToolchainRegistry
  private let connectionToClient: BuildSystemManagerConnectionToClient
  private let connectionToSourceKitLSP: any Connection

  package let configPath: URL

  private let swiftlyResolver = SwiftlyResolver()

  // Watch for all all changes to `compile_commands.json` and `compile_flags.txt` instead of just the one at
  // `configPath` so that we cover the following semi-common scenario:
  // The user has a build that stores `compile_commands.json` in `mybuild`. In order to pick it  up, they create a
  // symlink from `<project root>/compile_commands.json` to `mybuild/compile_commands.json`.  We want to get notified
  // about the change to `mybuild/compile_commands.json` because it effectively changes the contents of
  // `<project root>/compile_commands.json`.
  package let fileWatchers: [FileSystemWatcher] = [
    FileSystemWatcher(globPattern: "**/compile_commands.json", kind: [.create, .change, .delete]),
    FileSystemWatcher(globPattern: "**/.swift-version", kind: [.create, .change, .delete]),
  ]

  private var _indexStorePath: LazyValue<URL?> = .uninitialized
  package var indexStorePath: URL? {
    get async {
      guard let compdb = try? await compdbTask?.value else {
        return nil
      }
      return _indexStorePath.cachedValueOrCompute {
        for command in compdb.commands {
          if let indexStorePath = lastIndexStorePathArgument(in: command.commandLine) {
            return URL(
              fileURLWithPath: indexStorePath,
              relativeTo: URL(fileURLWithPath: command.directory, isDirectory: true)
            )
          }
        }
        return nil
      }
    }
  }

  package var indexDatabasePath: URL? {
    self.configPath.deletingLastPathComponent().appendingPathComponent("UniDB")
  }

  package nonisolated var supportsPreparationAndOutputPaths: Bool { false }
  private var directorySourceItems: Set<SourcesItem> = []

  package init(
    configPath: URL,
    toolchainRegistry: ToolchainRegistry,
    connectionToClient: BuildSystemManagerConnectionToClient,
    connectionToSourceKitLSP: any Connection
  ) async throws {
    self.compdbTask = Task { () throws -> BitSkyCompilationDatabase? in
      return try await BitSkyJSONCompilationDatabase.factory(file: configPath, connectionToClient: connectionToClient)
    }
    self.toolchainRegistry = toolchainRegistry
    self.connectionToClient = connectionToClient
    self.connectionToSourceKitLSP = connectionToSourceKitLSP
    self.configPath = configPath
  }

  package func buildTargets(request: WorkspaceBuildTargetsRequest) async throws -> WorkspaceBuildTargetsResponse {
    let compdb = try await compdbTask?.value
    let commands = compdb?.commands ?? []
    let compilers = Set(
      await commands.asyncCompactMap { (command) -> String? in
        await command.compiler(swiftlyResolver: swiftlyResolver)
      }
    ).sorted { $0 < $1 }
    let targets = try await compilers.asyncMap { compiler in
      let toolchainUri: URI? =
      if let toolchainPath = await toolchainRegistry.toolchain(withCompiler: URL(fileURLWithPath: compiler))?.path {
        URI(toolchainPath)
      } else {
        nil
      }
      return BuildTarget(
        id: try BuildTargetIdentifier.createCompileCommands(compiler: compiler),
        tags: [.test],
        capabilities: BuildTargetCapabilities(),
        // Be conservative with the languages that might be used in the target. SourceKit-LSP doesn't use this property.
        languageIds: [.c, .cpp, .objective_c, .objective_cpp, .swift],
        dependencies: [],
        dataKind: .sourceKit,
        data: SourceKitBuildTarget(toolchain: toolchainUri).encodeToLSPAny()
      )
    }
    return WorkspaceBuildTargetsResponse(targets: targets)
  }

  /// Lazily builds and returns the command trie.
  private func getCommandTrie() async throws -> PathTrie? {
    if let commandTrie {
      return commandTrie
    }
    guard let compdb = try await compdbTask?.value else {
      return nil
    }

    let newTrie = PathTrie()
    for command in compdb.commands {
      newTrie.insert(command: command)
    }
    self.commandTrie = newTrie
    return newTrie
  }

  /// Lazily builds and returns a dictionary of commands grouped by compiler.
  private func getCommandsByCompiler() async throws -> [String: [CompilationDatabaseCompileCommand]]? {
    if let commandsByCompiler {
      return commandsByCompiler
    }
    guard let compdb = try await compdbTask?.value else {
      return nil
    }

    var newMap: [String: [CompilationDatabaseCompileCommand]] = [:]
    for command in compdb.commands {
      if let compiler = await command.compiler(swiftlyResolver: swiftlyResolver) {
        newMap[compiler, default: []].append(command)
      }
    }
    self.commandsByCompiler = newMap
    return newMap
  }

  package func buildTargetSources(request: BuildTargetSourcesRequest) async throws -> BuildTargetSourcesResponse {
    guard let commandsByCompiler = try await getCommandsByCompiler() else {
      return BuildTargetSourcesResponse(items: [])
    }

    let items = request.targets.compactMap { (target) -> SourcesItem? in
      guard let targetCompiler = orLog("Compiler for target", { try target.compileCommandsCompiler }) else {
        return nil
      }

      // 2. Perform a fast dictionary lookup instead of filtering the whole database.
      let commandsForTarget = commandsByCompiler[targetCompiler] ?? []
      if commandsForTarget.isEmpty {
        return nil
      }

      var directoryDocumentURIs: Set<DocumentURI> = Set()

      // 3. Map the found commands to SourceItems and collect directories.
      let sources = commandsForTarget.map { command -> SourceItem in
        if let directory = command.uri.fileURL?.deletingLastPathComponent().path(percentEncoded: false) {
          directoryDocumentURIs.insert(DocumentURI(filePath: directory, isDirectory: true))
        }
        return SourceItem(uri: command.uri, kind: .file, generated: false)
      }

      // 4. Combine file sources with directory sources.
      let allSources = sources + directoryDocumentURIs.map {
        SourceItem(uri: $0, kind: .directory, generated: false)
      }

      return SourcesItem(target: target, sources: allSources)
    }

    return BuildTargetSourcesResponse(items: items)
  }

  package func didChangeWatchedFiles(notification: OnWatchedFilesDidChangeNotification) async {
    if notification.changes.contains(where: { $0.uri.fileURL?.lastPathComponent == Self.dbName }) {
      self.reloadCompilationDatabase()
    }
    if notification.changes.contains(where: { $0.uri.fileURL?.lastPathComponent == ".swift-version" }) {
      await swiftlyResolver.clearCache()
      connectionToSourceKitLSP.send(OnBuildTargetDidChangeNotification(changes: nil))
    }
  }

  package func prepare(request: BuildTargetPrepareRequest) async throws -> VoidResponse {
    throw ResponseError.methodNotFound(BuildTargetPrepareRequest.method)
  }

  package func sourceKitOptions(
    request: TextDocumentSourceKitOptionsRequest
  ) async throws -> TextDocumentSourceKitOptionsResponse? {
    let targetCompiler = try request.target.compileCommandsCompiler
    let compdb = try await compdbTask?.value

    let _command = await compdb?[request.textDocument.uri].asyncFilter {
      return await $0.compiler(swiftlyResolver: swiftlyResolver) == targetCompiler
    }.first

    let command: CompilationDatabaseCompileCommand?
    if let _command {
      command = _command
    } else {
      var inferredCommand: CompilationDatabaseCompileCommand? = nil

      // Priority 2: For header files, find the corresponding source file's command.
      let isHeader = request.textDocument.uri.fileURL?.pathExtension.lowercased() == "h" || request.textDocument.uri.fileURL?.pathExtension.lowercased() == "hpp"
      if isHeader, let headerURL = request.textDocument.uri.fileURL {
        // Look for .c, .m, .cpp, .mm files with the same name.
        let sourceExtensions = ["c", "m", "cpp", "mm"]
        let baseFileURL = headerURL.deletingPathExtension()

        for ext in sourceExtensions {
          let sourceFileURL = baseFileURL.appendingPathExtension(ext)
          let sourceDocURI = DocumentURI(sourceFileURL)
          if let sourceCommand = await compdb?[sourceDocURI].asyncFirst(where: { await $0.compiler(swiftlyResolver: swiftlyResolver) == targetCompiler }) {
            logger.info("Found command from counterpart source file: \(sourceDocURI.pseudoPath)")
            inferredCommand = sourceCommand
            break
          }
        }
      }
      // Priority 3: If still no command, use the PathTrie for the nearest neighbor.
      if inferredCommand == nil {
        logger.info("No counterpart source file found. Using PathTrie for nearest neighbor.")
        if let trie = try await getCommandTrie() {
          // We need to know what kind of file we are looking for.
          let fileExtension = request.textDocument.uri.fileURL?.pathExtension ?? ""
          if let trieCommand = trie.findCommand(for: request.textDocument.uri, fileExtension: fileExtension) {
            if await trieCommand.compiler(swiftlyResolver: swiftlyResolver) == targetCompiler {
              inferredCommand = trieCommand
            }
          }
        }
      }
      command = inferredCommand
      if let command = command {
        if request.language == .swift {
          var derivedArgs = Array(command.commandLine.dropFirst())
          derivedArgs.append(request.textDocument.uri.pseudoPath)
          return TextDocumentSourceKitOptionsResponse(
            compilerArguments: derivedArgs,
            workingDirectory: command.directory
          )
        } else if request.language == .c ||
                    request.language == .cpp ||
                    request.language == .objective_c ||
                    request.language == .objective_cpp
        {
          var derivedArgs = Array(command.commandLine.dropFirst())
          guard let cArgIndex = derivedArgs.firstIndex(of: "-c") else {
            return nil
          }
          let cArgNextIndex = derivedArgs.index(after: cArgIndex)
          if (cArgNextIndex < derivedArgs.endIndex) {
            derivedArgs[cArgNextIndex] = request.textDocument.uri.pseudoPath
          }
          return TextDocumentSourceKitOptionsResponse(
            compilerArguments: derivedArgs,
            workingDirectory: command.directory
          )
        }
      }
    }

    guard let command else {
      return nil
    }
    return TextDocumentSourceKitOptionsResponse(
      compilerArguments: Array(command.commandLine.dropFirst()),
      workingDirectory: command.directory
    )
  }

  package func waitForBuildSystemUpdates(request: WorkspaceWaitForBuildSystemUpdatesRequest) async -> VoidResponse {
    return VoidResponse()
  }

  /// The compilation database has been changed on disk.
  /// Reload it and notify the delegate about build setting changes.
  private func reloadCompilationDatabase() {
    orLog("Reloading compilation database") {
      self.compdbTask = Task { () throws -> BitSkyCompilationDatabase? in
        return try await BitSkyJSONCompilationDatabase.factory(file: configPath, connectionToClient: connectionToClient)
      }
      connectionToSourceKitLSP.send(OnBuildTargetDidChangeNotification(changes: nil))
    }
  }
}
