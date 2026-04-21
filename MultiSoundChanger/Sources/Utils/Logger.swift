//
//  Logger.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 20.04.21.
//  Copyright © 2021 Dmitry Medyuho. All rights reserved.
//

import Foundation

enum Logger {
    private enum DebugSymbol: String {
        case info = "🔵"
        case debug = "🟢"
        case warning = "🟠"
        case error = "🔴"
    }

    private enum Symbol: String {
        case newLine = "\n"
    }

    private enum LoggerError: Error {
        case fileError(String)
        case dataError
    }

    private static var isLogFileRemoved = false
    // Serialize and offload file I/O so per-keypress logging (AudioManager.selectDevice,
    // ApplicationController.onMediaKeyTap) doesn't stall the main thread on FileManager /
    // FileHandle syscalls.
    private static let fileWriteQueue = DispatchQueue(label: "com.multisoundchanger.logger")

    private static var bundleIdentifier: String {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            outPrint(symbol: .error, string: Constants.InnerMessages.bundleIdentifierError)
            fatalError(Constants.InnerMessages.bundleIdentifierError)
        }
        return bundleIdentifier
    }

    static func info(_ string: String) {
        outAndFilePrint(symbol: .info, string: string)
    }

    static func debug(_ string: String) {
        outAndFilePrint(symbol: .debug, string: string)
    }

    static func warning(_ string: String) {
        outAndFilePrint(symbol: .warning, string: string)
    }

    static func error(_ string: String) {
        outAndFilePrint(symbol: .error, string: string)
    }

    private static func getDebugLine(symbol: DebugSymbol, string: String) -> String {
        let logDate = getLogDate()
        return "\(symbol.rawValue) [\(logDate)] \(string)"
    }

    private static func outAndFilePrint(symbol: DebugSymbol, string: String) {
        outPrint(symbol: symbol, string: string)
        fileWriteQueue.async {
            do {
                try filePrint(symbol: symbol, string: string)
            } catch let error {
                // Print the file error back on main so it surfaces alongside the stdout stream.
                DispatchQueue.main.async {
                    outPrint(symbol: .error, string: error.localizedDescription)
                }
            }
        }
    }

    private static func outPrint(symbol: DebugSymbol, string: String) {
        let line = getDebugLine(symbol: symbol, string: string)
        print(line)
    }

    private static func filePrint(symbol: DebugSymbol, string: String, filename: String = Constants.logFilename) throws {
        do {
            var directoryUrl = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directoryUrl.appendPathComponent(bundleIdentifier)
            try createDirectoryIfNeeded(url: directoryUrl)
            let fileUrl = directoryUrl.appendingPathComponent(filename, isDirectory: false)
            let line = wrapNewLine(getDebugLine(symbol: symbol, string: string))
            try removeLogFileIfNeeded(url: fileUrl)
            try appendToFile(url: fileUrl, content: line)
        } catch let error {
            throw LoggerError.fileError(error.localizedDescription)
        }
    }

    private static func appendToFile(url: URL, content: String) throws {
        guard let data = content.data(using: .utf8) else {
            throw LoggerError.dataError
        }
        // Raw POSIX open with O_NOFOLLOW defends against a local attacker planting a symlink
        // at our log path (~/Library/Caches/<bundleID>/app.log) pointing at e.g. ~/.ssh/id_rsa,
        // which a naive FileHandle(forWritingTo:) would follow and end up appending log lines
        // into the symlink's target. O_NOFOLLOW makes open() fail with ELOOP instead.
        // Mode 0600 on creation keeps the log file user-only.
        let flags = O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW
        let fd = url.path.withCString { path in
            Darwin.open(path, flags, mode_t(0o600))
        }
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            throw LoggerError.fileError("open(\(url.path)) failed: \(reason) (errno=\(errno))")
        }
        defer { Darwin.close(fd) }

        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else {
                return -1
            }
            return Darwin.write(fd, base, buffer.count)
        }
        if written < 0 {
            let reason = String(cString: strerror(errno))
            throw LoggerError.fileError("write(\(url.path)) failed: \(reason) (errno=\(errno))")
        }
    }

    private static func createDirectoryIfNeeded(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
    }

    private static func removeLogFileIfNeeded(url: URL) throws {
        guard !isLogFileRemoved else {
            return
        }
        isLogFileRemoved = true
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func wrapNewLine(_ string: String) -> String {
        return string + Symbol.newLine.rawValue
    }

    private static func getLogDate() -> String {
        let date = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
