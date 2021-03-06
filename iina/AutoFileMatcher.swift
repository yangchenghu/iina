//
//  AutoFileMatcher.swift
//  iina
//
//  Created by lhc on 7/7/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation

class AutoFileMatcher {

  private enum AutoMatchingError: Error {
    case ticketExpired
  }

  weak private var player: PlayerCore!
  var ticket: Int

  private let fm = FileManager.default
  private let searchOptions: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]

  private var currentFolder: URL!
  private var filesGroupedByMediaType: [MPVTrack.TrackType: [FileInfo]] = [.video: [], .audio: [], .sub: []]
  private var videosGroupedBySeries: [String: [FileInfo]] = [:]
  private var subtitles: [FileInfo] = []
  private var subsGroupedBySeries: [String: [FileInfo]] = [:]
  private var unmatchedVideos: [FileInfo] = []

  init(player: PlayerCore, ticket: Int) {
    self.player = player
    self.ticket = ticket
  }

  /// checkTicket
  private func checkTicket() throws {
    if player.backgroundQueueTicket != ticket {
      throw AutoMatchingError.ticketExpired
    }
  }

  private func getAllMediaFiles() {
    // get all files in current directory
    guard let files = try? fm.contentsOfDirectory(at: currentFolder, includingPropertiesForKeys: nil, options: searchOptions) else { return }

    // group by extension
    for file in files {
      let fileInfo = FileInfo(file)
      if let mediaType = Utility.mediaType(forExtension: fileInfo.ext) {
        filesGroupedByMediaType[mediaType]!.append(fileInfo)
      }
    }

    // natural sort
    filesGroupedByMediaType[.video]!.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    filesGroupedByMediaType[.audio]!.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
  }

  private func getAllPossibleSubs() -> [FileInfo] {
    // search subs
    let subExts = Utility.supportedFileExt[.sub]!
    var subDirs: [URL] = []

    // search subs in other directories
    let rawUserDefinedSearchPaths = UserDefaults.standard.string(forKey: Preference.Key.subAutoLoadSearchPath) ?? "./*"
    let userDefinedSearchPaths = rawUserDefinedSearchPaths.components(separatedBy: ":").filter { !$0.isEmpty }
    for path in userDefinedSearchPaths {
      var p = path
      // handle `~`
      if path.hasPrefix("~") {
        p = NSString(string: path).expandingTildeInPath
      }
      if path.hasSuffix("/") { p.deleteLast(1) }
      // only check wildcard at the end
      let hasWildcard = path.hasSuffix("/*")
      if hasWildcard { p.deleteLast(2) }
      // handle absolute paths
      let pathURL = path.hasPrefix("/") || path.hasPrefix("~") ? URL(fileURLWithPath: p, isDirectory: true) : currentFolder.appendingPathComponent(p, isDirectory: true)
      // handle wildcards
      if hasWildcard {
        // append all sub dirs
        if let contents = try? fm.contentsOfDirectory(at: pathURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
          if #available(OSX 10.11, *) {
            subDirs.append(contentsOf: contents.filter { $0.hasDirectoryPath })
          } else {
            subDirs.append(contentsOf: contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false })
          }
        }
      } else {
        subDirs.append(pathURL)
      }
    }

    // get all possible sub files
    var subtitles = filesGroupedByMediaType[.sub]!
    for subDir in subDirs {
      if let contents = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil, options: searchOptions) {
        subtitles.append(contentsOf: contents.flatMap { subExts.contains($0.pathExtension.lowercased()) ? FileInfo($0) : nil })
      }
    }

    return subtitles
  }

  private func addFilesToPlaylist() throws {
    var addedCurrentVideo = false
    var needQuit = false

    // add videos
    for video in filesGroupedByMediaType[.video]! + filesGroupedByMediaType[.audio]! {
      // add to playlist
      if video.url.path == player.info.currentURL?.path {
        addedCurrentVideo = true
      } else if addedCurrentVideo {
        try checkTicket()
        player.addToPlaylist(video.path)
      } else {
        let count = player.mpvController.getInt(MPVProperty.playlistCount)
        let current = player.mpvController.getInt(MPVProperty.playlistPos)
        try checkTicket()
        player.addToPlaylist(video.path)
        player.mpvController.command(.playlistMove, args: ["\(count)", "\(current)"], checkError: false) { err in
          if err == MPV_ERROR_COMMAND.rawValue { needQuit = true }
        }
      }
      if needQuit { break }
    }
  }

  private func matchVideoAndSubSeries() -> [String: String] {
    var prefixDistance: [String: [String: UInt]] = [:]
    var closestVideoForSub: [String: String] = [:]

    // calculate edit distance between each v/s prefix
    for (sp, _) in subsGroupedBySeries {
      prefixDistance[sp] = [:]
      var minDist = UInt.max
      var minVideo = ""
      for (vp, vl) in videosGroupedBySeries {
        guard vl.count > 2 else { continue }
        let dist = ObjcUtils.levDistance(vp, and: sp)
        prefixDistance[sp]![vp] = dist
        if dist < minDist {
          minDist = dist
          minVideo = vp
        }
      }
      closestVideoForSub[sp] = minVideo
    }

    var matchedPrefixes: [String: String] = [:]  // video: sub
    for (vp, vl) in videosGroupedBySeries {
      guard vl.count > 2 else { continue }
      var minDist = UInt.max
      var minSub = ""
      for (sp, _) in subsGroupedBySeries {
        let dist = prefixDistance[sp]![vp]!
        if dist < minDist {
          minDist = dist
          minSub = sp
        }
      }
      let threshold = UInt(Double(vp.characters.count + minSub.characters.count) * 0.6)
      if closestVideoForSub[minSub] == vp && minDist < threshold {
        matchedPrefixes[vp] = minSub
      }
    }

    return matchedPrefixes
  }

  private func matchSubs(withMatchedSeries matchedPrefixes: [String: String]) throws {
    // get auto load option
    let subAutoLoadOption: Preference.IINAAutoLoadAction = Preference.IINAAutoLoadAction(rawValue: UserDefaults.standard.integer(forKey: Preference.Key.subAutoLoadIINA)) ?? .iina
    guard subAutoLoadOption != .disabled else { return }

    for video in filesGroupedByMediaType[.video]! {
      var matchedSubs = Set<FileInfo>()

      // match video and sub if both are the closest one to each other
      if subAutoLoadOption.shouldLoadSubsMatchedByIINA() {
        // is in series
        if !video.prefix.isEmpty, let matchedSubPrefix = matchedPrefixes[video.prefix] {
          // find sub with same name
          for sub in subtitles {
            guard let vn = video.nameInSeries, let sn = sub.nameInSeries else { continue }
            var nameMatched: Bool
            if let vnInt = Int(vn), let snInt = Int(sn) {
              nameMatched = vnInt == snInt
            } else {
              nameMatched = vn == sn
            }
            if nameMatched {
              video.relatedSubs.append(sub)
              if sub.prefix == matchedSubPrefix {
                try checkTicket()
                player.info.matchedSubs.safeAppend(sub.url, for: video.path)
                sub.isMatched = true
                matchedSubs.insert(sub)
              }
            }
          }
        }
      }

      // add subs that contains video name
      if subAutoLoadOption.shouldLoadSubsContainingVideoName() {
        try subtitles.filter {
          return $0.filename.contains(video.filename)
        }.forEach { sub in
          try checkTicket()
          player.info.matchedSubs.safeAppend(sub.url, for: video.path)
          sub.isMatched = true
          matchedSubs.insert(sub)
        }
      }

      // if no match
      if matchedSubs.isEmpty {
        unmatchedVideos.append(video)
      }

      // move the sub to front if it contains priority strings
      if let priorString = UserDefaults.standard.string(forKey: Preference.Key.subAutoLoadPriorityString), !matchedSubs.isEmpty {
        let stringList = priorString
          .components(separatedBy: ",")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        // find the min occurance count first
        var minOccurances = Int.max
        matchedSubs.forEach { sub in
          sub.priorityStringOccurances = stringList.reduce(0, { $0 + sub.filename.countOccurances(of: $1, in: nil) })
          if sub.priorityStringOccurances < minOccurances {
            minOccurances = sub.priorityStringOccurances
          }
        }
        try matchedSubs
          .filter { $0.priorityStringOccurances > minOccurances }  // eliminate false positives in filenames
          .flatMap { player.info.matchedSubs[video.path]!.index(of: $0.url) }  // get index
          .forEach {  // move the sub with index to first
            try checkTicket()
            if let s = player.info.matchedSubs[video.path]?.remove(at: $0) {
              player.info.matchedSubs[video.path]!.insert(s, at: 0)
            }
        }
      }
    }

    try checkTicket()
    player.info.currentVideosInfo = filesGroupedByMediaType[.video]!
  }

  private func forceMatchUnmatchedVideos() throws {
    let unmatchedSubs = subtitles.filter { !$0.isMatched }
    guard unmatchedVideos.count * unmatchedSubs.count < 200 * 200 else {
      Utility.log("Stopped auto matching subs - too much files")
      return
    }
    if unmatchedSubs.count > 0 && unmatchedVideos.count > 0 {
      // calculate edit distance
      for sub in unmatchedSubs {
        var minDistToVideo: UInt = .max
        for video in unmatchedVideos {
          try checkTicket()
          let threshold = UInt(Double(video.filename.characters.count + sub.filename.characters.count) * 0.6)
          let rawDist = ObjcUtils.levDistance(video.prefix, and: sub.prefix) + ObjcUtils.levDistance(video.suffix, and: sub.suffix)
          let dist: UInt = rawDist < threshold ? rawDist : UInt.max
          sub.dist[video] = dist
          video.dist[sub] = dist
          if dist < minDistToVideo { minDistToVideo = dist }
        }
        guard minDistToVideo != .max else { continue }
        sub.minDist = filesGroupedByMediaType[.video]!.filter { sub.dist[$0] == minDistToVideo }
      }

      // match them
      for video in unmatchedVideos {
        let minDistToSub = video.dist.reduce(UInt.max, { min($0.0, $0.1.value) })
        guard minDistToSub != .max else { continue }
        try checkTicket()
        unmatchedSubs
          .filter { video.dist[$0]! == minDistToSub && $0.minDist.contains(video) }
          .forEach { player.info.matchedSubs.safeAppend($0.url, for: video.path) }
      }
    }
  }

  func startMatching() {

    let shouldAutoLoad = UserDefaults.standard.bool(forKey: Preference.Key.playlistAutoAdd)

    do {

      guard let folder = player.info.currentURL?.deletingLastPathComponent(), folder.isFileURL else { return }
      currentFolder = folder

      getAllMediaFiles()

      // get all possible subtitles
      subtitles = getAllPossibleSubs()
      player.info.currentSubsInfo = subtitles

      // add files to playlist
      if shouldAutoLoad {
        try addFilesToPlaylist()
        NotificationCenter.default.post(name: Constants.Noti.playlistChanged, object: nil)
      }

      // group video and sub files
      videosGroupedBySeries = FileGroup.group(files: filesGroupedByMediaType[.video]!).flatten()
      subsGroupedBySeries = FileGroup.group(files: subtitles).flatten()

      // match video and sub series
      let matchedPrefixes = matchVideoAndSubSeries()

      // match sub stage 1
      try matchSubs(withMatchedSeries: matchedPrefixes)
      NotificationCenter.default.post(name: Constants.Noti.playlistChanged, object: nil)

      // match sub stage 2
      if shouldAutoLoad {
        try forceMatchUnmatchedVideos()
        NotificationCenter.default.post(name: Constants.Noti.playlistChanged, object: nil)
      }

    } catch {
      return
    }
  }

}
