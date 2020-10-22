//===--------------- IncrementalCompilation.swift - Incremental -----------===//
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
import TSCBasic
import Foundation
import SwiftOptions
@_spi(Testing) public class IncrementalCompilationState {

  /// The oracle for deciding what depends on what. Applies to this whole module.
  public let moduleDependencyGraph: ModuleDependencyGraph

  /// If non-null outputs information for `-driver-show-incremental` for input path
  public let reportIncrementalDecision: ((String, TypedVirtualPath?) -> Void)?

  /// The primary input files that are part of the first wave
  let firstWaveInputs: [TypedVirtualPath]

  /// Inputs that must be compiled, and swiftDeps processed.
  /// When empty, the compile phase is done.
  var pendingInputs: Set<TypedVirtualPath>

  /// Input files that were skipped.
  /// May shrink if one of these moves into pendingInputs.
  var skippedCompilationInputs: Set<TypedVirtualPath>

  /// Jobs that were skipped.
  /// Redundant with `skippedCompilationInputs`
  /// TODO: Incremental. clean up someday. Should only need one.
  var skippedCompileJobs = [TypedVirtualPath: Job]()

  /// Accumulates jobs to be run as a result of dynamic discovery
  public var dynamicallyDiscoveredJobs = SynchronizedQueue<Job>()

  /// Jobs to run after the last compile
  private var postCompileJobs = [Job]()


  /// A check for reentrancy.
  private var amHandlingJobCompletion = false

// MARK: - Creating IncrementalCompilationState if possible
  /// Return nil if not compiling incrementally
  public init?(
    buildRecordInfo: BuildRecordInfo?,
    compilerMode: CompilerMode,
    diagnosticEngine: DiagnosticsEngine,
    fileSystem: FileSystem,
    inputFiles: [TypedVirtualPath],
    outputFileMap: OutputFileMap?,
    parsedOptions: inout ParsedOptions,
    showJobLifecycle: Bool
  ) {
    guard Self.shouldAttemptIncrementalCompilation(
            parsedOptions: &parsedOptions,
            compilerMode: compilerMode,
            diagnosticEngine: diagnosticEngine)
    else {
      return nil
    }

    guard let outputFileMap = outputFileMap,
          let buildRecordInfo = buildRecordInfo
    else {
      diagnosticEngine.emit(.warning_incremental_requires_output_file_map)
      return nil
    }

    // FIXME: This should work without an output file map. We should have
    // another way to specify a build record and where to put intermediates.
    guard let outOfDateBuildRecord = buildRecordInfo.populateOutOfDateBuildRecord(
            inputFiles: inputFiles,
            failed: {
              diagnosticEngine.emit(
                .remark_incremental_compilation_disabled(because: $0))
            })
    else {
      return nil
    }

    let reportIncrementalDecision =
      parsedOptions.hasArgument(.driverShowIncremental) || showJobLifecycle
      ? { Self.reportIncrementalDecisionFn($0, $1, outputFileMap, diagnosticEngine) }
      : nil

    guard let moduleDependencyGraph =
            ModuleDependencyGraph.buildInitialGraph(
              diagnosticEngine: diagnosticEngine,
              inputs: buildRecordInfo.compilationInputModificationDates.keys,
              outputFileMap: outputFileMap,
              parsedOptions: &parsedOptions,
              remarkDisabled: Diagnostic.Message.remark_incremental_compilation_disabled,
              reportIncrementalDecision: reportIncrementalDecision)
    else {
      return nil
    }

    (firstWave: self.firstWaveInputs, skipped: self.skippedCompilationInputs)
      = Self.computeFirstWaveVsSkippedCompilationInputs(
        inputFiles: inputFiles,
        buildRecordInfo: buildRecordInfo,
        moduleDependencyGraph: moduleDependencyGraph,
        outOfDateBuildRecord: outOfDateBuildRecord,
        reportIncrementalDecision: reportIncrementalDecision)

    self.pendingInputs = Set(firstWaveInputs)
    self.moduleDependencyGraph = moduleDependencyGraph
    self.reportIncrementalDecision = reportIncrementalDecision

    maybeFinishedWithCompilations()
  }

  /// Check various arguments to rule out incremental compilation if need be.
  private static func shouldAttemptIncrementalCompilation(
    parsedOptions: inout ParsedOptions,
    compilerMode: CompilerMode,
    diagnosticEngine: DiagnosticsEngine
  ) -> Bool {
    guard parsedOptions.hasArgument(.incremental) else {
      return false
    }
    guard compilerMode.supportsIncrementalCompilation else {
      diagnosticEngine.emit(
        .remark_incremental_compilation_disabled(
          because: "it is not compatible with \(compilerMode)"))
      return false
    }
    guard !parsedOptions.hasArgument(.embedBitcode) else {
      diagnosticEngine.emit(
        .remark_incremental_compilation_disabled(
          because: "is not currently compatible with embedding LLVM IR bitcode"))
      return false
    }
    return true
  }
}

fileprivate extension CompilerMode {
  var supportsIncrementalCompilation: Bool {
    switch self {
    case .standardCompile, .immediate, .repl, .batchCompile: return true
    case .singleCompile, .compilePCM: return false
    }
  }
}

// MARK: - Outputting debugging info
fileprivate extension IncrementalCompilationState {
  private static func reportIncrementalDecisionFn(
    _ s: String,
    _ path: TypedVirtualPath?,
    _ outputFileMap: OutputFileMap,
    _ diagnosticEngine: DiagnosticsEngine
  ) {
    let IO = path.flatMap {
      $0.type == .swift ? $0.file : outputFileMap.getInput(outputFile: $0.file)
    }
    .map {($0.basename,
           outputFileMap.getOutput(inputFile: $0, outputType: .object).basename
    )}
    let pathPart = IO.map { " {compile: \($0.1) <= \($0.0)}" }
    let message = "\(s)\(pathPart ?? "")"
    diagnosticEngine.emit(.remark_incremental_compilation(because: message))
  }
}

extension Diagnostic.Message {
  static var warning_incremental_requires_output_file_map: Diagnostic.Message {
    .warning("ignoring -incremental (currently requires an output file map)")
  }
  static var warning_incremental_requires_build_record_entry: Diagnostic.Message {
    .warning(
      "ignoring -incremental; " +
        "output file map has no master dependencies entry under \(FileType.swiftDeps)"
    )
  }
  static func remark_incremental_compilation_disabled(because why: String) -> Diagnostic.Message {
    .remark("Incremental compilation has been disabled, because \(why)")
  }
  static func remark_incremental_compilation(because why: String) -> Diagnostic.Message {
    .remark("Incremental compilation: \(why)")
  }
}


// MARK: - Scheduling the first wave

extension IncrementalCompilationState {
  private static func computeFirstWaveVsSkippedCompilationInputs(
    inputFiles: [TypedVirtualPath],
    buildRecordInfo: BuildRecordInfo,
    moduleDependencyGraph: ModuleDependencyGraph,
    outOfDateBuildRecord: BuildRecord,
    reportIncrementalDecision: ((String, TypedVirtualPath?) -> Void)?
  ) -> (firstWave: [TypedVirtualPath], skipped: Set<TypedVirtualPath>) {

    let changedInputs: [(TypedVirtualPath, InputInfo.Status)] = computeChangedInputs(
      inputFiles: inputFiles,
      buildRecordInfo: buildRecordInfo,
      moduleDependencyGraph: moduleDependencyGraph,
      outOfDateBuildRecord: outOfDateBuildRecord,
      reportIncrementalDecision: reportIncrementalDecision)
    let externalDependents = computeExternallyDependentInputs(
      buildTime: outOfDateBuildRecord.buildTime,
      fileSystem: buildRecordInfo.fileSystem,
      moduleDependencyGraph: moduleDependencyGraph,
      reportIncrementalDecision: reportIncrementalDecision)

    // Combine to obtain the inputs that definitely must be recompiled.
    let definitelyRequiredFirstWaveInputs = Set(changedInputs.map {$0.0} + externalDependents)
    if let report = reportIncrementalDecision {
      for scheduledInput in definitelyRequiredFirstWaveInputs.sorted(by: {$0.file.name < $1.file.name}) {
        report("Queuing (initial):", scheduledInput)
      }
    }

    // Sometimes, inputs run in the first wave that depend on the changed inputs for the
    // first wave, even though they may not require compilation.
    // Any such inputs missed, will be found by the rereading of swiftDeps
    // as each first wave job finished.
    let speculativeFirstWaveInputs = computeSpeculativeFirstWaveInputs(
      changedInputs: changedInputs,
      moduleDependencyGraph: moduleDependencyGraph,
      reportIncrementalDecision: reportIncrementalDecision)
      .subtracting(definitelyRequiredFirstWaveInputs)

    if let report = reportIncrementalDecision {
      for dependent in speculativeFirstWaveInputs.sorted(by: {$0.file.name < $1.file.name}) {
        report("Queuing (dependent):", dependent)
      }
    }
    let firstWaveInputs = Array(definitelyRequiredFirstWaveInputs.union(speculativeFirstWaveInputs))
      .sorted {$0.file.name < $1.file.name}

    let skippedInputs = Set(buildRecordInfo.compilationInputModificationDates.keys)
      .subtracting(firstWaveInputs)
    for skippedInput in skippedInputs.sorted(by: {$0.file.name < $1.file.name})  {
      reportIncrementalDecision?("Skipping:", skippedInput)
    }
    return (firstWave: firstWaveInputs, skipped: skippedInputs)
  }

  /// Find the inputs that have changed since last compilation, or were marked as needed a build
  private static func computeChangedInputs(
    inputFiles: [TypedVirtualPath],
    buildRecordInfo: BuildRecordInfo,
    moduleDependencyGraph: ModuleDependencyGraph,
    outOfDateBuildRecord: BuildRecord,
    reportIncrementalDecision: ((String, TypedVirtualPath?) -> Void)?
   ) -> [(TypedVirtualPath, InputInfo.Status)] {
    inputFiles.compactMap { input in
      guard input.type.isPartOfSwiftCompilation else {
        return nil
      }
      let modDate = buildRecordInfo.compilationInputModificationDates[input]
        ?? Date.distantFuture
      let previousCompilationStatus = outOfDateBuildRecord
        .inputInfos[input.file]?.status ?? .newlyAdded

      switch previousCompilationStatus {
      // Using outOfDateBuildRecord.inputInfos[input.file]?.previousModTime
      // has some inaccuracy.
      // Use outOfDateBuildRecord.buildTime instead
      case .upToDate where modDate < outOfDateBuildRecord.buildTime:
        reportIncrementalDecision?("Skipping current", input)
        return nil

      case .upToDate:
        reportIncrementalDecision?("Scheduing changed input", input)
      case .newlyAdded:
        reportIncrementalDecision?("Scheduling new", input)
      case .needsCascadingBuild:
        reportIncrementalDecision?("Scheduling cascading build", input)
      case .needsNonCascadingBuild:
        reportIncrementalDecision?("Scheduling noncascading build", input)
      }
      return (input, previousCompilationStatus)
    }
  }


  /// Any files dependent on modified files from other modules must be compiled, too.
  private static func computeExternallyDependentInputs(
    buildTime: Date,
    fileSystem: FileSystem,
    moduleDependencyGraph: ModuleDependencyGraph,
    reportIncrementalDecision: ((String, TypedVirtualPath?) -> Void)?
 ) -> [TypedVirtualPath] {
    var externallyDependentSwiftDeps = Set<ModuleDependencyGraph.SwiftDeps>()
    for extDep in moduleDependencyGraph.externalDependencies {
      let extModTime = extDep.file.flatMap {
        try? fileSystem.getFileInfo($0).modTime}
        ?? Date.distantFuture
      if extModTime >= buildTime {
        moduleDependencyGraph.forEachUntracedSwiftDepsDirectlyDependent(on: extDep) {
          reportIncrementalDecision?(
            "Scheduling externally-dependent on newer  \(extDep.file?.basename ?? "extDep?")",
            TypedVirtualPath(file: $0.file, type: .swiftDeps))
          externallyDependentSwiftDeps.insert($0)
        }
      }
    }
    return externallyDependentSwiftDeps.compactMap {
      moduleDependencyGraph.sourceSwiftDepsMap[$0]
    }
  }

  /// Returns the cascaded files to compile in the first wave, even though it may not be need.
  /// The needs[Non}CascadingBuild stuff was cargo-culted from the legacy driver.
  /// TODO: something better, e.g. return nothing here, but process changes swiftDeps from 1st wave
  /// before the whole frontend job finished.
  private static func computeSpeculativeFirstWaveInputs(
    changedInputs: [(TypedVirtualPath, InputInfo.Status)],
    moduleDependencyGraph: ModuleDependencyGraph,
    reportIncrementalDecision: ((String, TypedVirtualPath?) -> Void)?
    ) -> Set<TypedVirtualPath> {
    // Collect the files that will be compiled whose dependents should be schedule
    let cascadingFiles: [TypedVirtualPath] = changedInputs.compactMap { input, status in
      let basename = input.file.basename
      switch status {
      case .needsCascadingBuild:
        reportIncrementalDecision?(
          "scheduling dependents of \(basename); needed cascading build", nil)
        return input

      case .upToDate: // Must be building because it changed
        reportIncrementalDecision?(
          "not scheduling dependents of \(basename); unknown changes", nil)
        return nil
       case .newlyAdded:
        reportIncrementalDecision?(
          "not scheduling dependents of \(basename): no entry in build record or dependency graph", nil)
        return nil
      case .needsNonCascadingBuild:
        reportIncrementalDecision?(
          "not scheduling dependents of \(basename): does not need cascading build", nil)
        return nil
      }
    }
    // Collect the dependent files to speculatively schedule
    var dependentFiles = Set<TypedVirtualPath>()
    let cascadingFileSet = Set(cascadingFiles)
    for cascadingFile in cascadingFiles {
       let dependentsOfOneFile = moduleDependencyGraph
        .findDependentSourceFiles(of: cascadingFile, reportIncrementalDecision)
      for dep in dependentsOfOneFile where !cascadingFileSet.contains(dep) {
        if dependentFiles.insert(dep).0 {
          reportIncrementalDecision?(
            "Immediately scheduling dependent on \(cascadingFile.file.basename)", dep)
        }
      }
    }
    return dependentFiles
  }
}

// MARK: - Scheduling 2nd wave
extension IncrementalCompilationState {
  /// Remember a skipped job
  func addSkippedCompileJobs(_ jobs: [Job]) {
    for job in jobs {
      for input in job.primaryInputs {
        reportIncrementalDecision?("Skipping", input)
        if let _ = skippedCompileJobs.updateValue(job, forKey: input) {
          fatalError("should not have two skipped jobs for same skipped input")
        }
      }
    }
  }

  /// Remember a job that runs after all compile jobs
  func addPostCompileJobs(_ jobs: [Job]) {
    for job in jobs {
      for input in job.primaryInputs {
        reportIncrementalDecision?("Delaying pending discovering delayed dependencies", input)
      }
      // UGH!
      if dynamicallyDiscoveredJobs.isOpen {
        postCompileJobs.append(contentsOf: jobs)
      }
      else {
        dynamicallyDiscoveredJobs.append(contentsOf: jobs)
      }
    }
  }

  /// Update the incremental build state when a job finishes:
  /// Read it's swiftDeps files and queue up any required 2nd wave jobs.
  func jobFinished(job: Job, result: ProcessResult) {
    defer {
      amHandlingJobCompletion = false
    }
    assert(!amHandlingJobCompletion, "was reentered, need to synchronize")
    amHandlingJobCompletion = true

    let secondWaveInputs = collectInputsToCompileIn2ndWave(job)
    for input in secondWaveInputs {
      reportIncrementalDecision?(
        "Queuing because of dependencies discovered later:", input)
    }
    rememberInputsFor2ndWave(secondWaveInputs)
    job.primaryInputs.forEach {pendingInputs.remove($0)}
    maybeFinishedWithCompilations()
 }

  private func collectInputsToCompileIn2ndWave(
    _ job: Job
  ) -> [TypedVirtualPath] {
    Array(
      Set(
        job.primaryInputs.flatMap {
          moduleDependencyGraph.findSourcesToCompileAfterCompiling($0)
            ?? Array(skippedCompilationInputs)
        }
      )
    )
    .sorted {$0.file.name < $1.file.name}
  }

  private func rememberInputsFor2ndWave(_ sources: [TypedVirtualPath]) {
    for input in sources {
      if let job = skippedCompileJobs.removeValue(forKey: input) {
        skippedCompilationInputs.subtract(job.primaryInputs)
        rememberJobFor2ndWave(job)
      }
      else {
        reportIncrementalDecision?("Tried to schedule 2nd wave input again", input)
      }
    }
  }

  private func rememberJobFor2ndWave(_ j: Job) {
    for input in j.primaryInputs {
      reportIncrementalDecision?("Scheduling for 2nd wave", input)
    }
    dynamicallyDiscoveredJobs.append(j)
  }

  func maybeFinishedWithCompilations() {
    if pendingInputs.isEmpty {
      dynamicallyDiscoveredJobs.append(contentsOf: postCompileJobs)
      postCompileJobs.removeAll()
      dynamicallyDiscoveredJobs.close()
    }
  }
}

