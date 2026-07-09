//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import BuildServerIntegration
import Foundation
import IndexStoreDB
@_spi(SourceKitLSP) package import LanguageServerProtocol
import Markdown
package import SKOptions
package import SourceKitLSP
import SwiftExtensions
import SwiftParser
package import SwiftSyntax
package import ToolchainRegistry

package actor DocumentationLanguageService: LanguageService, Sendable {
  /// The ``SourceKitLSPServer`` instance that created this `DocumentationLanguageService`.
  weak let sourceKitLSPServer: SourceKitLSPServer?

  let documentationManager: DocCDocumentationManager

  var documentManager: DocumentManager {
    get throws {
      guard let sourceKitLSPServer else {
        throw ResponseError.unknown("Connection to the editor closed")
      }
      return sourceKitLSPServer.documentManager
    }
  }

  let workspace: Workspace

  package static var experimentalCapabilities: [String: LSPAny] {
    return [
      DoccDocumentationRequest.method: ["version": 1],
      "definitionProvider": .bool(true),
    ]
  }

  package init(
    sourceKitLSPServer: SourceKitLSPServer,
    toolchain: Toolchain,
    options: SourceKitLSPOptions,
    hooks: Hooks,
    workspace: Workspace
  ) async throws {
    self.sourceKitLSPServer = sourceKitLSPServer
    self.documentationManager = DocCDocumentationManager(buildServerManager: workspace.buildServerManager);
    self.workspace = workspace
  }

  package nonisolated func canHandle(toolchain: Toolchain) -> Bool {
    return true
  }

  package func shutdown() async {
    // Nothing to tear down
  }

  package func addStateChangeHandler(
    handler: @escaping @Sendable (LanguageServerState, LanguageServerState) -> Void
  ) async {
    // There is no underlying language server with which to report state
  }

  package func openDocument(
    _ notification: DidOpenTextDocumentNotification,
    snapshot: DocumentSnapshot
  ) async {
    schedulePublishSymbolLinkDiagnostics(for: snapshot.uri)
  }

  private func publishSymbolLinkDiagnostics(for uri: DocumentURI) async {
    guard let sourceKitLSPServer else { return }
    guard let snapshot = try? self.documentManager.latestSnapshot(uri) else { return }
    guard !Task.isCancelled else { return }

    let symbolLinks = collectSymbolLinks(in: snapshot)
    guard let symbols = await loadSymbolGraph(for: uri) else {
      // Module hasn't built yet don't give out diagnotics
      return
    }
    guard !Task.isCancelled else { return }

    let diagnostics: [Diagnostic] = symbolLinks.compactMap { link in
      guard matchingSymbol(for: link.symbol, in: symbols) == nil else { return nil }
      return Diagnostic(
        range: link.range,
        severity: .error,
        source: "SourceKit-LSP",
        message: "No symbol link resolved for '\(link.symbol)'"
      )
    }

    sourceKitLSPServer.sendNotificationToClient(
      PublishDiagnosticsNotification(uri: uri, diagnostics: diagnostics)
    )
  }
  /// Loads and parses the symbol graph of current Document's module
  private func loadSymbolGraph(for currentDocumentURI: DocumentURI) async -> [[String: Any]]? {
    guard let targetID = await self.workspace.buildServerManager.targets(for: currentDocumentURI).first,
      let moduleName = await self.workspace.buildServerManager.moduleName(for: targetID)
    else {
      return nil
    }

    let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let targetGraphURL =
      workspaceRoot
      .appendingPathComponent(".build/symbol-graphs")
      .appendingPathComponent("\(moduleName).symbols.json")

    guard let data = try? Data(contentsOf: targetGraphURL),
      let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let symbolsArray = jsonObject["symbols"] as? [[String: Any]]
    else {
      return nil
    }
    return symbolsArray
  }

  /// Finds the symbol graph entry matching `symbolPath` (e.g. "Sloth/energy"), if any.
  private func matchingSymbol(for symbolPath: String, in symbols: [[String: Any]]) -> [String: Any]? {
    let pathComponents = symbolPath.components(separatedBy: "/")
    let symbolName = pathComponents.last ?? symbolPath

    for symbol in symbols {
      guard let namesDict = symbol["names"] as? [String: Any],
        let title = namesDict["title"] as? String,
        title == symbolName
      else { continue }

      if pathComponents.count > 1 {
        guard let symbolPathComponents = symbol["pathComponents"] as? [String] else { continue }
        guard Array(symbolPathComponents.suffix(pathComponents.count)) == pathComponents else { continue }
      }
      return symbol
    }
    return nil
  }

  package func closeDocument(_ notification: DidCloseTextDocumentNotification) async {
    cancelInFlightPublishDiagnosticsTask(for: notification.textDocument.uri)
    inFlightPublishDiagnosticsTasks[notification.textDocument.uri] = nil
  }

  package func reopenDocument(_ notification: ReopenTextDocumentNotification) async {
    // The DocumentationLanguageService does not do anything with document events
  }

  package func syntacticTestItems(for snapshot: DocumentSnapshot) async -> [AnnotatedTestItem]? {
    // We know documentation files have no test cases.
    return []
  }

  package func syntacticPlaygrounds(
    for snapshot: DocumentSnapshot,
    in workspace: Workspace
  ) async -> [TextDocumentPlayground] {
    return []
  }

  package func changeDocument(
    _ notification: DidChangeTextDocumentNotification,
    preEditSnapshot: DocumentSnapshot,
    postEditSnapshot: DocumentSnapshot,
    edits: [SwiftSyntax.SourceEdit]
  ) async {
    schedulePublishSymbolLinkDiagnostics(for: postEditSnapshot.uri)
  }

  package func symbolInfo(_ req: SymbolInfoRequest) async throws -> [SymbolDetails] {
    return []
  }

  package func definition(_ req: DefinitionRequest) async throws -> LocationsOrLocationLinksResponse? {

    let snapshot = try self.documentManager.latestSnapshot(req.textDocument.uri)
    let clickedSymbol: String?
    if snapshot.language == .swift {
      clickedSymbol = extractSymbolFromDocComment(snapshot: snapshot, at: req.position)
    } else {
      clickedSymbol = extractSymbolFromText(snapshot.text, at: req.position)
    }

    guard let clickedSymbol else {
      return nil
    }

    guard
      let targetLocation = await findLocationInSymbolGraphs(
        for: clickedSymbol,
        currentDocumentURI: req.textDocument.uri
      )
    else {
      return nil
    }
    return .locations([targetLocation])
  }

  /// A symbol link found while walking a Markdown/DocC AST, e.g. ``Sloth/energy``.
  private struct SymbolLinkReference {
    let symbol: String
    let range: Markdown.SourceRange
  }

  /// Walks the Markdown/DocC AST collecting every symbol link in the document.
  /// Used both for go-to-definition (find the one under the cursor) and diagnostics (validate all of them).
  private struct SymbolLinkCollector: MarkupWalker {
    var found: [SymbolLinkReference] = []

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
      if let range = symbolLink.range, let destination = symbolLink.destination {
        found.append(SymbolLinkReference(symbol: destination, range: range))
      }
    }

    mutating func defaultVisit(_ markup: any Markup) {
      descendInto(markup)
    }
  }

  /// Parses `text` once, walks it once, and returns the symbol link whose range contains `target`, if any.
  private func symbolLink(
    at target: Markdown.SourceLocation,
    in text: String,
    options: ParseOptions = [.parseSymbolLinks]
  ) -> String? {
    let document = Markdown.Document(parsing: text, options: options)
    var collector = SymbolLinkCollector()
    collector.visit(document)
    return collector.found.first { $0.range.lowerBound <= target && target < $0.range.upperBound }?.symbol
  }

  private func extractSymbolFromText(_ text: String, at position: Position) -> String? {
    let target = Markdown.SourceLocation(
      line: position.line + 1,
      column: position.utf16index + 1,
      source: nil
    )
    return symbolLink(at: target, in: text, options: [.parseSymbolLinks, .parseBlockDirectives])
  }

  private func extractSymbolFromDocComment(snapshot: DocumentSnapshot, at position: Position) -> String? {
    let sourceFile = SwiftParser.Parser.parse(source: snapshot.text)
    let absolutePosition = snapshot.absolutePosition(of: position)

    guard let token = sourceFile.token(at: absolutePosition) else {
      return nil
    }

    let converter = SourceLocationConverter(fileName: "", tree: sourceFile)
    let cursorLine = converter.location(for: absolutePosition).line
    let cursorColumn = converter.location(for: absolutePosition).column

    var triviaOffset = token.position.utf8Offset

    for piece in token.leadingTrivia.pieces {
      defer { triviaOffset += piece.sourceLength.utf8Length }

      switch piece {
      case .docLineComment(let commentText):
        let pieceStartLine = converter.location(for: AbsolutePosition(utf8Offset: triviaOffset)).line
        guard pieceStartLine == cursorLine else { continue }

        let triviaStartColumn = converter.location(for: AbsolutePosition(utf8Offset: triviaOffset)).column
        let relativeColumn = cursorColumn - triviaStartColumn + 1

        let target = Markdown.SourceLocation(line: 1, column: relativeColumn, source: nil)
        if let found = symbolLink(at: target, in: commentText) {
          return found
        }

      case .docBlockComment:
        // Symbol link navigation within /** */ blocks is not yet supported.
        continue

      default:
        continue
      }
    }
    return nil
  }

  private func findLocationInSymbolGraphs(for symbolPath: String, currentDocumentURI: DocumentURI) async -> Location? {
    guard let symbols = await loadSymbolGraph(for: currentDocumentURI),
      let symbol = matchingSymbol(for: symbolPath, in: symbols),
      let locationDict = symbol["location"] as? [String: Any],
      let uriString = locationDict["uri"] as? String,
      let positionDict = locationDict["position"] as? [String: Any],
      let line = positionDict["line"] as? Int,
      let character = positionDict["character"] as? Int,
      let targetURI = try? DocumentURI(string: uriString)
    else {
      return nil
    }
    let position = Position(line: line, utf16index: character)
    return Location(uri: targetURI, range: position..<position)
  }

  private var inFlightPublishDiagnosticsTasks: [DocumentURI: Task<Void, Never>] = [:]

  private func cancelInFlightPublishDiagnosticsTask(for uri: DocumentURI) {
    inFlightPublishDiagnosticsTasks[uri]?.cancel()
  }

  private func schedulePublishSymbolLinkDiagnostics(for uri: DocumentURI) {
    cancelInFlightPublishDiagnosticsTask(for: uri)
    inFlightPublishDiagnosticsTasks[uri] = Task(priority: .medium) { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return  // cancelled by a newer edit
      }
      await self?.publishSymbolLinkDiagnostics(for: uri)
    }
  }

  private func collectSymbolLinks(in snapshot: DocumentSnapshot) -> [(symbol: String, range: Range<Position>)] {
    snapshot.language == .swift
      ? collectSymbolLinksInSwiftDocComments(snapshot)
      : collectSymbolLinksInMarkdown(snapshot.text)
  }

  private func collectSymbolLinksInMarkdown(_ text: String) -> [(symbol: String, range: Range<Position>)] {
    let document = Markdown.Document(parsing: text, options: [.parseSymbolLinks, .parseBlockDirectives])
    var collector = SymbolLinkCollector()
    collector.visit(document)

    return collector.found.map { link in
      let start = Position(line: link.range.lowerBound.line - 1, utf16index: link.range.lowerBound.column - 1)
      let end = Position(line: link.range.upperBound.line - 1, utf16index: link.range.upperBound.column - 1)
      return (link.symbol, start..<end)
    }
  }

  private func collectSymbolLinksInSwiftDocComments(
    _ snapshot: DocumentSnapshot
  ) -> [(symbol: String, range: Range<Position>)] {
    let sourceFile = SwiftParser.Parser.parse(source: snapshot.text)
    let converter = SourceLocationConverter(fileName: "", tree: sourceFile)
    var results: [(symbol: String, range: Range<Position>)] = []

    for token in sourceFile.tokens(viewMode: .sourceAccurate) {
      var triviaOffset = token.position.utf8Offset
      for piece in token.leadingTrivia.pieces {
        defer { triviaOffset += piece.sourceLength.utf8Length }
        guard case .docLineComment(let commentText) = piece else { continue }

        let triviaStart = converter.location(for: AbsolutePosition(utf8Offset: triviaOffset))
        let document = Markdown.Document(parsing: commentText, options: [.parseSymbolLinks])
        var collector = SymbolLinkCollector()
        collector.visit(document)

        for link in collector.found {
          let startColumn = triviaStart.column + link.range.lowerBound.column - 1
          let endColumn = triviaStart.column + link.range.upperBound.column - 1
          let line = triviaStart.line - 1
          results.append(
            (
              link.symbol,
              Position(line: line, utf16index: startColumn - 1)..<Position(line: line, utf16index: endColumn - 1)
            )
          )
        }
      }
    }
    return results
  }
}
