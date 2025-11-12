import Foundation
import SKOptions
import ToolchainRegistry
import CryptoKit
import LanguageServerProtocol
import LanguageServerProtocolExtensions
import SKLogging
import SwiftExtensions
import TSCExtensions
import class TSCBasic.Process

let ToolchainCodingUserInfoKey = CodingUserInfoKey(rawValue: "toolchain")!
let SourceKitLSPOptionsCodingUserInfoKey = CodingUserInfoKey(rawValue: ".sourcekit-lsp/config.json")!
let ProgressRepoterCodingUserInfoKey = CodingUserInfoKey(rawValue: "progressRepoter")!

extension FileManager {
  fileprivate func chdir(at url: URL, block: () throws -> Void) throws {
    let oldPWD = FileManager.default.currentDirectoryPath
    FileManager.default.changeCurrentDirectoryPath(url.path(percentEncoded: false))
    defer { FileManager.default.changeCurrentDirectoryPath(oldPWD) }
    try block()
  }
}

public func createSymbolicLink(sourcePath: String, destinationPath: String) throws {
  let fileManager = FileManager.default

  let originLinkPath = (try? fileManager.destinationOfSymbolicLink(atPath: destinationPath)) ?? ""
  if !originLinkPath.isEmpty {
    if originLinkPath == sourcePath {
      logger.debug("\(destinationPath) symlinkpath is same as \(sourcePath)")
      return
    } else {
      try fileManager.removeItem(atPath: destinationPath)
    }
  }
  try fileManager.createSymbolicLink(atPath: destinationPath, withDestinationPath: sourcePath)
}

class IndexHeaderSearchPathGenerator {
  static let bitSkyPublicHeadersPath = "Headers/Public"
  private let workspacePath: String
  private var running: Bool = false
  init(workspacePath: String) {
    self.workspacePath = workspacePath
  }

  func handleBitskyHeadersSearchPath() async throws {
    if running {
      logger.warning("handleBitskyHeadersSearchPath is runinng")
      return
    }
    defer {
      self.running = false
    }
    running = true
    let tempPublicHeadersPath = NSTemporaryDirectory() + "BitSkyHeaders" + UUID().uuidString
    if tempPublicHeadersPath.exists {
      try tempPublicHeadersPath.delete()
    }
    try tempPublicHeadersPath.mkpath()
    let bazelWorkspacePath = workspacePath + "/bazel-\(workspacePath.basename)"
    let externalPath = bazelWorkspacePath + "/external"
    let externalBinPath = workspacePath + "/bazel-out/bitsky-universal/bin/external"
    let modulePath = workspacePath + "/Module"

    var componentHeaderPathDict: [String: [String: String]] = [:]
    func setComponentHeaderPathDict(_ c: String, _ h: String, _ p: String) {
      if componentHeaderPathDict[c] == nil {
        componentHeaderPathDict[c] = [:]
      }
      componentHeaderPathDict[c]![h] = p
    }

    // 优先创建软链 链接到 external/component/pod_support/Headers/Public
    if externalPath.exists {
      for component in try FileManager.default.contentsOfDirectory(atPath: externalPath).map({ externalPath + "/" + $0 }) {
        let componentPodsupportHeadersPublic = component + "/pod_support/Headers/Public"
        let componentPodsupportHeadersPrivate = component + "/pod_support/Headers/Private"
        let componentPodsupportHeaders = [componentPodsupportHeadersPublic, componentPodsupportHeadersPrivate]
        for componentPodsupportHeader in componentPodsupportHeaders {
          if componentPodsupportHeader.exists, componentPodsupportHeader.isDirectory {
            let componentName = component.basename
            let fileIterator = FileManager.default.enumerator(at: componentPodsupportHeader.url, includingPropertiesForKeys: nil, options: [])
            while let file = fileIterator?.nextObject() as? URL {
              if file.pathString.isSymlink {
                let realFile = file.resolvingSymlinksInPath().pathString
                setComponentHeaderPathDict(componentName, file.lastPathComponent, realFile)
              }
            }
          }
        }
      }
    }

    // 头条工程 Module 下组件平铺，从 ModuleHeaders/HmapSource 获取 头文件
    let moduleHeadersHmapSource = modulePath + "/ModuleHeaders/HmapSource"
    if moduleHeadersHmapSource.exists {
      let fileIterator = FileManager.default.enumerator(at: moduleHeadersHmapSource.url, includingPropertiesForKeys: nil, options: [])
      while let file = fileIterator?.nextObject() as? URL {
        if file.lastPathComponent.hasSuffix("_namespace.hmapsource") || file.lastPathComponent.hasSuffix("_namespaced.hmapsource") {
          let hmapsource = try NSString(contentsOfFile: file.pathString, encoding: NSUTF8StringEncoding)
          // ie./Users/bytedance/Desktop/bytedance/bitsky/rules_xcodeproj/tools/generators/legacy/src/Generator/BitskyGenerator/BitskyWriteXcodeproj.swift BDADBaseLib/TTTemailTracker.h|Module/BDADBaseLib/BDADBaseLib/Classes/Tracker/TTTemailTracker.h
          for line in hmapsource.components(separatedBy: .newlines) {
            let separatedLine = line.components(separatedBy: "|")
            if separatedLine.count == 2 {
              let namespacedCompoenetHeaders = separatedLine[0]
              let destinationHeaderPath = workspacePath + "/" + separatedLine[1]
              let separatedNamespacedCompoenetHeaders = namespacedCompoenetHeaders.components(separatedBy: "/")
              if separatedNamespacedCompoenetHeaders.count == 2 {
                let componentName = separatedNamespacedCompoenetHeaders[0]
                let componentHeader = separatedNamespacedCompoenetHeaders[1]
                setComponentHeaderPathDict(componentName, componentHeader, destinationHeaderPath)
              }
            }
          }
        }
      }
    }
    // 后续其他业务 Module 下组件不会平铺，没有 ModuleHeaders/HmapSource，可以从 externalBinPath/component 下的 hmapsource 获取头文件
    if externalBinPath.exists {
      for component in try FileManager.default.contentsOfDirectory(atPath: externalBinPath).map({ externalBinPath + "/" + $0 }) {
        let componentName = component.basename
        if componentName != "PodHeaders", componentHeaderPathDict[componentName] == nil {
          for childFile in try FileManager.default.contentsOfDirectory(atPath: component).map({ component + "/" + $0 }) where childFile.pathExtension == "hmapsource" {
            let hmapsource = try NSString(contentsOfFile: childFile, encoding: NSUTF8StringEncoding)
            // ie. GeckoSwitch.h|external/AAFastbotTweak/pod_support/Headers/Public/GeckoSwitch.h
            for line in hmapsource.components(separatedBy: .newlines) {
              let separatedLine = line.components(separatedBy: "|")
              if separatedLine.count == 2 {
                let componentHeader = separatedLine[0]
                let destinationHeaderPath = bazelWorkspacePath + "/" + separatedLine[1]
                setComponentHeaderPathDict(componentName, componentHeader, destinationHeaderPath)
              }
            }
          }
        }
      }
    }
    // create symlink
    for (componentName, headersMap) in componentHeaderPathDict {
      if headersMap[componentName] != nil {
        // symlick public dir
        if let destinationHeaderPublicPath = headersMap[componentName] {
          let publicHeadersPathComponent = tempPublicHeadersPath + "/" + componentName
          if destinationHeaderPublicPath.exists {
            do {
              try FileManager.default.createSymbolicLink(atPath: publicHeadersPathComponent, withDestinationPath: destinationHeaderPublicPath)
            } catch {
              logger.warning("Symlink \(publicHeadersPathComponent) to \(destinationHeaderPublicPath) failed!")
            }
          }
        }
      } else {
        // symlink header file
        if !headersMap.isEmpty {
          let publicHeadersPathComponent = tempPublicHeadersPath + "/" + componentName
          try publicHeadersPathComponent.mkpath()
          for (headerFileName, realHeaderFilePath) in headersMap {
            let publicHeadersPathComponentHeader = publicHeadersPathComponent + "/" + headerFileName
            if realHeaderFilePath.exists {
              do {
                try createSymbolicLink(sourcePath: realHeaderFilePath, destinationPath: publicHeadersPathComponentHeader)
              } catch {
                logger.warning("Symlink \(publicHeadersPathComponentHeader) to \(realHeaderFilePath) failed!")
              }
            }
          }
        }
      }
    }

    let publicHeadersPath = workspacePath + "/.bitsky/temp/" + IndexHeaderSearchPathGenerator.bitSkyPublicHeadersPath
    try publicHeadersPath.mkpath()
    let process = Process(arguments: ["/bin/bash", "-c", "rsync --archive --links --chmod=u+w,F-x --delete \(tempPublicHeadersPath)/ \(publicHeadersPath)"])
    try process.launch()
    _ = try await process.waitUntilExit()
    try? tempPublicHeadersPath.delete()
  }
}

package struct BitSkyCompilationDatabaseCompileCommand: Equatable, Codable {

  /// The working directory for the compilation.
  package var directory: String

  /// The path of the main file for the compilation, which may be relative to `directory`.
  package var filename: String?

  package var filenames: [String]?

  /// The compile command as a list of strings, with the program name first.
  package var commandLine: [String]

  /// The name of the build output, or nil.
  package var output: String? = nil

  package init(directory: String, filename: String, commandLine: [String], output: String? = nil) {
    self.directory = directory
    self.filename = filename
    self.commandLine = commandLine
    self.output = output
  }

  private enum CodingKeys: String, CodingKey {
    case directory
    case file
    case files
    case command
  }

  package init(from decoder: Decoder) throws {
    guard let toolchain = decoder.userInfo[ToolchainCodingUserInfoKey] as? Toolchain else {
      throw NSError(domain: "Decode BitSkyCompilationDatabaseCompileCommand must pass userInfo with ToolchainCodingUserInfoKey", code: 10001)
    }
    guard let developerDir = {
      var url = toolchain.path
      url.deleteLastPathComponent()
      url.deleteLastPathComponent()
      return url
    }() else {
      throw NSError(domain: "failed to fetch developer dir from toolchain ", code: 10002)
    }
    let isUniqBazelServer = CanonicalDocumentURIConvert.shared.getUniqBazelServerOption();
    let executionRoot = CanonicalDocumentURIConvert.shared.getExecutionRoot()
    self.directory = executionRoot
    let outputBase = CanonicalDocumentURIConvert.shared.getOutputBase()
    let outputBaseURL = URL(fileURLWithPath: outputBase)
    let executionRootURL = URL(fileURLWithPath: executionRoot)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let filenameStr = try? container.decode(String.self, forKey: .file) {
      self.filename = filenameStr
    }
    if let filenamesStr = try? container.decode(String.self, forKey: .files) {
      self.filenames = []
      for filename in filenamesStr.split(separator: ",") {
        self.filenames?.append(String(filename))
      }
    }
    if let command = try container.decodeIfPresent(String.self, forKey: .command) {
#if os(Windows)
      self.commandLine = splitWindowsCommandLine(command, initialCommandName: true)
#else
      let matches = try! NSRegularExpression(pattern:"\"[^\"]+\"|\\S+").matches(in: command, options: [], range: NSRange(command.startIndex..., in: command))
      let args = matches.map { match in
        var subArg = (command as NSString).substring(with: match.range)
        if subArg.hasPrefix("\"") && subArg.hasSuffix("\"") {
          subArg.removeFirst("\"".count)
          subArg.removeLast("\"".count)
        }
        return subArg
      }
      var commandLine: [String] = [String]()
      var isSwift = false
      var skipNext = false
      var prevArgument: String = ""
      var target: String? = nil
      var argIt = args.enumerated().makeIterator()
      while let (i, argument) = argIt.next() {
        defer {
          prevArgument = argument
        }
        if target == nil && prevArgument == "-target" {
          target = argument
        }
        if skipNext {
          skipNext = false
          continue
        }
        if i == 0 {
          if argument.hasSuffix("clang") {
            commandLine.append("clang")
          } else if argument.hasSuffix("clang_pp") {
            commandLine.append("clang++")
          } else if argument.hasSuffix("worker") {
            isSwift = true
            continue
          } else {
            commandLine.append(argument)
          }
        } else {
          if argument == "__BAZEL_XCODE_SDKROOT__" {
            if let target = target {
              if target.hasSuffix("-simulator") {
                commandLine.append(developerDir.appending(path: "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk").path(percentEncoded: false))
              } else {
                commandLine.append(developerDir.appending(path: "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk").path(percentEncoded: false))
              }
            } else {
              commandLine.append(developerDir.appending(path: "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk").path(percentEncoded: false))
            }
          }
          else if argument.hasPrefix("-F__BAZEL_XCODE_SDKROOT__") {
            var argument = argument
            argument.removeFirst("-F__BAZEL_XCODE_SDKROOT__".count)
            if let target = target {
              if target.hasSuffix("-simulator") {
                commandLine.append("-F\(developerDir.appending(path: "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk").path(percentEncoded: false))\(argument)")
              } else {
                commandLine.append("-F\(developerDir.appending(path: "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk").path(percentEncoded: false))\(argument)")
              }
            } else {
              commandLine.append("-F\(developerDir.appending(path: "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk").path(percentEncoded: false))\(argument)")
            }
          }
          else if argument.hasPrefix("-F__BAZEL_XCODE_DEVELOPER_DIR__") {
            var argument = argument
            argument.removeFirst("-F__BAZEL_XCODE_DEVELOPER_DIR__".count)
            var developDirPath = developerDir.path(percentEncoded: false)
            if developDirPath.hasSuffix("/") {
              developDirPath.removeLast("/".count)
            }
            commandLine.append("-F\(developDirPath)\(argument)")
          }
          // 转化成绝对路径保证#import可以补全
          else if argument.hasPrefix("-F") {
            var argument = argument
            argument.removeFirst("-F".count)
            guard !argument.hasPrefix("/") else {
              commandLine.append("-F\(argument)")
              continue
            }
            let absArgument = executionRootURL.appending(path: argument).path(percentEncoded: false)
            if !isUniqBazelServer {
              let fixedArgument = absArgument.replacingOccurrences(of: "/execroot/", with: "/rules_xcodeproj.noindex/indexbuild_output_base/execroot/")
              commandLine.append("-F\(fixedArgument)")
            } else {
              commandLine.append("-F\(absArgument)")
            }
          }
          // 转化成绝对路径保证#import可以补全
          else if argument.hasPrefix("-I") {
            var argument = argument
            argument.removeFirst("-I".count)
            guard !argument.hasPrefix("/") else {
              commandLine.append("-I\(argument)")
              continue
            }
            let absArgument = executionRootURL.appending(path: argument).path(percentEncoded: false)
            if argument == "." {
              // 针对.特殊处理，不进行转换。避免因为 index prebuild 时external下的路径不存在导致报错头文件找不到
              commandLine.append("-I\(argument)")
            } else {
              let finalArgument: String
              if !isUniqBazelServer {
                let fixedArgument = absArgument.replacingOccurrences(of: "/execroot/", with: "/rules_xcodeproj.noindex/indexbuild_output_base/execroot/")
                finalArgument = fixedArgument
              } else {
                finalArgument = absArgument
              }
              commandLine.append("-I\(finalArgument)")
            }
          }
          else if !isSwift && argument == "-c" {
            skipNext = true
            continue
          }
          // vscode 编辑索引要求vfs必须要绝对路径
          else if !isSwift && argument.hasPrefix("-ivfsoverlay") {
            var argument = argument
            argument.removeFirst("-ivfsoverlay".count)
            let absArgument = executionRootURL.appending(path: argument).path(percentEncoded: false)
            if !isUniqBazelServer {
              let fixedArgument = absArgument.replacingOccurrences(of: "/execroot/", with: "/rules_xcodeproj.noindex/indexbuild_output_base/execroot/")
              commandLine.append("-ivfsoverlay\(fixedArgument)")
            } else {
              commandLine.append("-ivfsoverlay\(absArgument)")
            }
          }
          else if isSwift && argument == "-load-plugin-executable" && i+2 <= args.count && args[i+1] == "-Xfrontend" {
            commandLine.append(argument)
            let dylibPath = args[i+2]
            if !dylibPath.starts(with: "/") {
              let nextArg = argIt.next()
              commandLine.append(nextArg!.element)
              _ = argIt.next()
              commandLine.append(executionRootURL.appending(path: dylibPath).path(percentEncoded: false))
            }
            continue
          }
          else if isSwift && argument.hasPrefix("-Xwrapped-swift=") {
            continue
          }
          // vscode 编辑索引要求vfs必须要绝对路径
          else if isSwift && argument.hasPrefix("-vfsoverlay") {
            var argument = argument
            argument.removeFirst("-vfsoverlay".count)
            let absArgument = executionRootURL.appending(path: argument).path(percentEncoded: false)
            if !isUniqBazelServer {
              let fixedArgument = absArgument.replacingOccurrences(of: "/execroot/", with: "/rules_xcodeproj.noindex/indexbuild_output_base/execroot/")
              commandLine.append("-vfsoverlay\(fixedArgument)")
            } else {
              commandLine.append("-vfsoverlay\(absArgument)")
            }
          }
          // vscode 编辑索引要求vfs必须要绝对路径
          else if isSwift && argument.hasPrefix("-ivfsoverlay") {
            var argument = argument
            argument.removeFirst("-ivfsoverlay".count)
            let absArgument = executionRootURL.appending(path: argument).path(percentEncoded: false)
            if !isUniqBazelServer {
              let fixedArgument = absArgument.replacingOccurrences(of: "/execroot/", with: "/rules_xcodeproj.noindex/indexbuild_output_base/execroot/")
              commandLine.append("-ivfsoverlay\(fixedArgument)")
            } else {
              commandLine.append("-ivfsoverlay\(absArgument)")
            }
          }
          else if isSwift && (argument == "-emit-module-path" || argument == "-emit-objc-header-path" || argument == "-emit-module-interface-path" || argument == "-emit-const-values-path" || argument == "-parseable-output") {
            skipNext = true
            continue
          }
          else if isSwift && (argument.hasSuffix(".swift") && !argument.hasPrefix("-")) {
            if !argument.starts(with: "/") && !argument.starts(with: "bazel-out") {
              do {
                let bazelSymlinkFullFilename = if argument.hasPrefix("external/") {
                  outputBaseURL.appending(path: argument)
                } else {
                  executionRootURL.appending(path: argument)
                }
                let realFilename = try bazelSymlinkFullFilename.realpath.path(percentEncoded: false)
                commandLine.append(realFilename)
              } catch {
                // 加入原始路径，可能swift导致索引异常，但比崩溃要好一些。
                commandLine.append(argument)
              }
            } else {
              commandLine.append(argument)
            }
            continue
          }
          else {
            commandLine.append(argument)
          }
        }
      }
      if !isSwift {
        commandLine.append("-I\(self.directory.appending("/.bitsky/temp/Headers/Public"))")
      }
      self.commandLine = commandLine
#endif
    } else {
      throw CompilationDatabaseDecodingError.missingCommandOrArguments
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(directory, forKey: .directory)
    try container.encode(filename, forKey: .file)
  }
}

func processCCCommand(command: inout CompilationDatabaseCompileCommand, realFilename: String, sourceKitLSPOptions: SourceKitLSPOptions) {
  command.commandLine.append("-c")
  command.commandLine.append(realFilename)

  if realFilename.hasSuffix(".c") {
    command.commandLine.append("-xc")
  } else if realFilename.hasSuffix(".cpp") || realFilename.hasSuffix(".cc") {
    command.commandLine.append("-xc++")
  } else if realFilename.hasSuffix(".m") {
    command.commandLine.append("-xobjective-c")
  } else if realFilename.hasSuffix(".mm") {
    command.commandLine.append("-xobjective-c++")
  }

  command.commandLine.append("-ivfsoverlay")
  command.commandLine.append(command.directory.appending("/.bitsky/temp/bazel-out-overlay.yaml"))

  let indexStorePath = CanonicalDocumentURIConvert.shared.getIndexStorePath()
  command.commandLine.append("-index-store-path")
  command.commandLine.append(indexStorePath)

  command.commandLine.append("-working-directory")
  command.commandLine.append(command.directory)
}

func processSwiftCommand(command: inout CompilationDatabaseCompileCommand, sourceKitLSPOptions: SourceKitLSPOptions) {
  let bazelOutVFSPath = command.directory.appending("/.bitsky/temp/bazel-out-overlay.yaml")

  command.commandLine.append("-vfsoverlay")
  command.commandLine.append(bazelOutVFSPath)
  command.commandLine.append("-Xcc")
  command.commandLine.append("-ivfsoverlay")
  command.commandLine.append("-Xcc")
  command.commandLine.append(bazelOutVFSPath)
  let indexStorePath = CanonicalDocumentURIConvert.shared.getIndexStorePath()
  command.commandLine.append("-index-store-path")
  command.commandLine.append(indexStorePath)

  command.commandLine.append("-working-directory")
  command.commandLine.append(command.directory)
  command.commandLine.append("-Xcc")
  command.commandLine.append("-working-directory")
  command.commandLine.append("-Xcc")
  command.commandLine.append(command.directory)
}

func convertBitSkyCompileCommand(bitskyCompileCommand: BitSkyCompilationDatabaseCompileCommand, realFilename: String, sourceKitLSPOptions: SourceKitLSPOptions) -> CompilationDatabaseCompileCommand {
  var compileCommand = CompilationDatabaseCompileCommand.init(directory: bitskyCompileCommand.directory, filename: realFilename, commandLine: bitskyCompileCommand.commandLine);

  if realFilename.hasSuffix(".swift") {
    processSwiftCommand(command: &compileCommand, sourceKitLSPOptions: sourceKitLSPOptions)
  } else {
    processCCCommand(command: &compileCommand, realFilename: realFilename, sourceKitLSPOptions: sourceKitLSPOptions)
  }
  return compileCommand
}

struct FileFingerprint: Hashable {
  @MainActor static var cacheHash = Cache<FileFingerprint, String?>()

  let file: URL
  let modifyTime: Double?

  init(file: URL) {
    var modifyTime: Double?
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      if let modificationDate = attributes[.modificationDate] as? Date {
        modifyTime = modificationDate.timeIntervalSince1970
      }
    } catch {}
    self.file = file
    self.modifyTime = modifyTime
  }

  @MainActor static func getHash(_ fingerprint: FileFingerprint) async -> String? {
    return try? await cacheHash.get(fingerprint, isolation: MainActor.shared) {  cacheFingerprint in
      return Insecure.MD5.hash(
        data: try Data(contentsOf: fingerprint.file)
      )
      .map { String(format: "%02hhx", $0) }  // maps each byte of the hash to its hex equivalent `String`
      .joined()
    }
  }
}

actor GenericCacheActor<Key: Sendable & Hashable, Value: Sendable> {
  private let cache = Cache<Key, Value>()

  func getOrCompute(
    for key: Key,
    compute: @Sendable @escaping (Key) async throws -> Value
  ) async throws -> Value {
    return try await cache.get(key, isolation: self, compute: compute)
  }

  func getDerivedOrCompute(
    for key: Key,
    canReuseKey: @Sendable @escaping (Key) async -> Bool,
    transform: @Sendable @escaping (Value) -> Value
  ) async throws -> Value? {
    return try await cache.getDerived(
      isolation: self,
      key,
      canReuseKey: canReuseKey,
      transform: transform
    )
  }

  func clear(where condition: (Key) -> Bool) {
    cache.clear(isolation: self, where: condition)
  }

  func clearAll() {
    cache.clearAll(isolation: self)
  }
}

actor CompileCommandProgressReporter {
  private let connection: BuildSystemManagerConnectionToClient
  private let token: ProgressToken = .string("build-compdb")

  private var hasSendCreateRequest = false
  private var lastMessageTime: Date? = nil
  private var queue: [() async -> Void] = []
  private var isExecuting = false

  init(connection: BuildSystemManagerConnectionToClient) {
    self.connection = connection
  }

  private func enqueue(_ task: @escaping () async -> Void) {
    queue.append(task)
    if !isExecuting {
      Task {
        await self.runNext()
      }
    }
  }

  private func runNext() async {
    guard !isExecuting, !queue.isEmpty else { return }
    isExecuting = true
    let task = queue.removeFirst()
    await task()
    isExecuting = false
    await runNext()
  }

  func reportStart(title: String, message: String?) {
    enqueue {
      do {
        await self.connection.waitUntilInitialized()
        _ = try await self.connection.send(CreateWorkDoneProgressRequest(token: self.token))
        self.hasSendCreateRequest = true

        self.connection.send(
          WorkDoneProgress(token: self.token, value: .begin(
            WorkDoneProgressBegin(title: title, cancellable: false, message: message)
          ))
        )
      } catch {
        // Ignore
      }
    }
  }

  func reportEnd(message: String) {
    enqueue {
      guard self.hasSendCreateRequest else { return }
      self.connection.send(
        WorkDoneProgress(token: self.token, value: .end(
          WorkDoneProgressEnd(message: message)
        ))
      )
    }
  }

  func reportMessage(_ msg: String) {
    enqueue {
      guard self.hasSendCreateRequest else { return }
      let now = Date()
      if let last = self.lastMessageTime, now.timeIntervalSince(last) < 0.2 {
        return
      }
      self.lastMessageTime = now
      self.connection.send(
        WorkDoneProgress(token: self.token, value: .report(
          WorkDoneProgressReport(message: msg)
        ))
      )
    }
  }
}

typealias CompilationDatabaseCache = GenericCacheActor<FileFingerprint, BitSkyCompilationDatabase?>
typealias SourcekitLSPOptionsCache = GenericCacheActor<URL, SourceKitLSPOptions>

let cacheCompilationDatabase = CompilationDatabaseCache()
let cacheSourcekitLSPOptions = SourcekitLSPOptionsCache()

package struct BitSkyJSONCompilationDatabase: Equatable, Codable {

  let commands: [BitSkyCompilationDatabaseCompileCommand]

  var compilationDatabase: BitSkyCompilationDatabase

  @MainActor static var toolchainRegistry = ToolchainRegistry(installPath: Bundle.main.bundleURL)

  static func factory(file: URL, connectionToClient: BuildSystemManagerConnectionToClient) async throws -> BitSkyCompilationDatabase? {
    let progressRepoter = CompileCommandProgressReporter(connection: connectionToClient)
    Task {
      await progressRepoter.reportStart(title: "BitSky Index: 加载/更新索引编译参数 / Load or Update Index Compile Arguments", message: "正在加载索引参数 / Loading index arguments...")
    }
    let finalDB = try await _factory(file: file, progressRepoter: progressRepoter);
    Task {
      if finalDB == nil {
        await progressRepoter.reportEnd(message: "索引参数为空 / Empty")
      } else {
        await progressRepoter.reportEnd(message: "加载完成 / Done")
      }
    }
    return finalDB
  }

  private static func _factory(file: URL, progressRepoter: CompileCommandProgressReporter) async throws -> BitSkyCompilationDatabase? {
    guard file.path(percentEncoded: false).contains(".bitsky/temp/") else {
      return nil
    }
    let compileCommandsJSONURL = file
    guard FileManager.default.fileExists(at: compileCommandsJSONURL) == true else {
      return nil
    }
    let fingerprint = FileFingerprint(file: compileCommandsJSONURL)
    let derivedCompDb = try? await cacheCompilationDatabase.getDerivedOrCompute(for: fingerprint) { cacheFingerprint in
      let isSameFile = (try? cacheFingerprint.file.realpath == fingerprint.file.realpath) ?? false
      if isSameFile && cacheFingerprint.modifyTime == fingerprint.modifyTime {
        return true
      }
      if isSameFile {
        if await FileFingerprint.getHash(cacheFingerprint) ==  FileFingerprint.getHash(fingerprint) {
          return true
        }
      }
      return false
    } transform: { cachedResult in
      return cachedResult
    }
    if let derivedCompDb = derivedCompDb, derivedCompDb != nil {
      return derivedCompDb
    }
    await cacheCompilationDatabase.clear { cacheFingerprint in
      return (try? cacheFingerprint.file.realpath == compileCommandsJSONURL.realpath) ?? false
    }
    _ = await FileFingerprint.getHash(fingerprint)
    let toolchain = await toolchainRegistry.default

    let sourceKitLSPOptions: SourceKitLSPOptions

    if let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
      let bazelInfoJsonPath = try configHome.replacing(Regex("/temp.*"), with: "/Config/bazel_info.json")
      let sourceKitLSPOptionsConfigURL = URL(filePath: configHome).appending(path: "/sourcekit-lsp/config.json")

      if let data = try? Data.init(contentsOf: URL(filePath: bazelInfoJsonPath)) {
        if let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
          if let workspacePath = jsonObj["workspace"], let outputBase = jsonObj["output_base"], let executionRoot = jsonObj["execution_root"] {
            await CanonicalDocumentURIConvert.shared.preload(workspacePath: workspacePath, outputBase: outputBase, executionRoot: executionRoot, filePath: "\(workspacePath)/.bitsky/temp/sourcemap_info_files.json" ,sourceKitLSPOptionsConfigURL: sourceKitLSPOptionsConfigURL)
            Task {
              async let _ = IndexHeaderSearchPathGenerator(workspacePath: workspacePath).handleBitskyHeadersSearchPath()
            }
          } else {
            throw NSError(domain: "failed to get workspacePath/outputBase/executionRoot", code: 10001)
          }
        }
      }

      sourceKitLSPOptions = try await cacheSourcekitLSPOptions.getOrCompute(for: sourceKitLSPOptionsConfigURL) { cacheURL in
        let data = try Data(contentsOf: cacheURL)
        let sourceKitLSPOptions = try JSONDecoder().decode(SourceKitLSPOptions.self, from: data)
        return sourceKitLSPOptions
      }
    } else {
      sourceKitLSPOptions = SourceKitLSPOptions()
    }

    return try? await cacheCompilationDatabase.getOrCompute(for: fingerprint) { _ in
      let bitskyCompilationDatabase = try? BitSkyJSONCompilationDatabase(file: compileCommandsJSONURL,
                                                                         sourceKitLSPOptions: sourceKitLSPOptions,
                                                                         progressRepoter: progressRepoter,
                                                                         toolchain: toolchain)
      if let bitskyCompilationDatabase = bitskyCompilationDatabase {
        return bitskyCompilationDatabase.compilationDatabase
      }
      return nil
    }
  }

  package init(from decoder: Decoder) throws {
    guard let sourceKitLSPOptions = decoder.userInfo[SourceKitLSPOptionsCodingUserInfoKey] as? SourceKitLSPOptions else {
      throw NSError(domain: "Decode BitSkyCompilationDatabaseCompileCommand must pass userInfo with SourceKitLSPOptionsCodingUserInfoKey", code: 10001)
    }
    guard let progressRepoter = decoder.userInfo[ProgressRepoterCodingUserInfoKey] as? CompileCommandProgressReporter else {
      throw NSError(domain: "Decode BitSkyCompilationDatabaseCompileCommand must pass userInfo with ProgressRepoterCodingUserInfoKey", code: 10002)
    }

    logger.log(level: .info, "load bitsky compile commands. begin at \(Date())")
    compilationDatabase = BitSkyCompilationDatabase()
    commands = []
    var container = try decoder.unkeyedContainer()

    let outputBase = CanonicalDocumentURIConvert.shared.getOutputBase()
    let outputBaseURL = URL(fileURLWithPath: outputBase)
    let outputBaseExternal = outputBase.appending("/external")
    let executionRoot = CanonicalDocumentURIConvert.shared.getExecutionRoot()
    let executionRootURL = URL(fileURLWithPath: executionRoot)

    while !container.isAtEnd {
      try autoreleasepool {
        let bitskyCompileCommand = try container.decode(BitSkyCompilationDatabaseCompileCommand.self)
        var firstProcessedCompileCommand: CompilationDatabaseCompileCommand? = nil
        var firstOriginFilename: String? = nil
        if let filename = bitskyCompileCommand.filename {
          let bazelSymlinkFullFilename = if filename.hasPrefix("external/") {
            outputBaseURL.appending(path: filename)
          } else {
            executionRootURL.appending(path: filename)
          }
          guard let realFilename = try? bazelSymlinkFullFilename.realpath.path(percentEncoded: false) else {
            return
          }
          // 把原路径的文件加进来。方便vscode中根据原路径匹配编译参数。
          let compileCommand = convertBitSkyCompileCommand(bitskyCompileCommand: bitskyCompileCommand, realFilename: realFilename, sourceKitLSPOptions: sourceKitLSPOptions)
          compilationDatabase.add(compileCommand)
          Task {
            await progressRepoter.reportMessage(filename)
          }
          firstProcessedCompileCommand = compileCommand
          firstOriginFilename = filename
        } else if let filenames = bitskyCompileCommand.filenames {
          for (_, filename) in filenames.enumerated() {
            autoreleasepool {
              let bazelSymlinkFullFilename = if filename.hasPrefix("external/") {
                outputBaseURL.appending(path: filename)
              } else {
                executionRootURL.appending(path: filename)
              }
              guard let realFilename = try? bazelSymlinkFullFilename.realpath.path(percentEncoded: false) else {
                return
              }
              // 把原路径的文件加进来。方便vscode中根据原路径匹配编译参数。
              let compileCommand = convertBitSkyCompileCommand(bitskyCompileCommand: bitskyCompileCommand,
                                                               realFilename: realFilename,
                                                               sourceKitLSPOptions: sourceKitLSPOptions)
              compilationDatabase.add(compileCommand)
              Task {
                await progressRepoter.reportMessage(filename)
              }
              if firstProcessedCompileCommand == nil {
                firstProcessedCompileCommand = compileCommand
                firstOriginFilename = filename
              }
            }
          }
        }
      }
    }

    logger.log(level: .info, "load bitsky compile commands. end at \(Date())")
  }

  /// Loads the compilation database located in `directory`, if any.
  ///
  /// - Returns: `nil` if `compile_commands.json` was not found
  init?(directory: URL, sourceKitLSPOptions: SourceKitLSPOptions, progressRepoter: CompileCommandProgressReporter, toolchain: Toolchain?) throws {
    let path = directory.appending(component: "compile_commands.json")
    try self.init(file: path, sourceKitLSPOptions: sourceKitLSPOptions, progressRepoter: progressRepoter, toolchain: toolchain)
  }

  /// Loads the compilation database from `file`
  /// - Returns: `nil` if the file does not exist
  init?(file: URL, sourceKitLSPOptions: SourceKitLSPOptions, progressRepoter: CompileCommandProgressReporter, toolchain: Toolchain?) throws {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.userInfo[ToolchainCodingUserInfoKey] = toolchain
    decoder.userInfo[SourceKitLSPOptionsCodingUserInfoKey] = sourceKitLSPOptions
    decoder.userInfo[ProgressRepoterCodingUserInfoKey] = progressRepoter

    self = try decoder.decode(BitSkyJSONCompilationDatabase.self, from: data)
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    try commands.forEach { try container.encode($0) }
  }

  package static func == (lhs: Self, rhs: Self) -> Bool {
    return lhs.commands == rhs.commands && lhs.compilationDatabase == rhs.compilationDatabase
  }
}
