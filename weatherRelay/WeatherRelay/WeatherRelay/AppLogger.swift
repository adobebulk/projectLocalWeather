//
//  AppLogger.swift
//  WeatherRelay
//
//  Created by Codex on 2026-03-14.
//

import Foundation

final class AppLogger {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "com.ctsmith.weatherrelay.applogger")
    private let fileManager = FileManager.default
    private let maxBytes: Int64 = 1_048_576
    private let currentFileName = "weatherRelay.log"
    private let previousFileName = "weatherRelay_prev.log"

    private init() {
        queue.sync {
            ensureCurrentFileExists()
        }
    }

    func log(category: String, message: String) {
        let line = "[\(Self.timestampFormatter.string(from: Date()))] [\(category)] \(message)\n"

        queue.async {
            self.rotateIfNeeded(forAdditionalBytes: Int64(line.utf8.count))
            self.appendLine(line)
        }

        print(line.trimmingCharacters(in: .newlines))
    }

    func currentLogFileURL() -> URL {
        queue.sync {
            ensureCurrentFileExists()
            return currentLogURL
        }
    }

    func readCurrentLog() -> String {
        queue.sync {
            ensureCurrentFileExists()
            guard
                let data = try? Data(contentsOf: currentLogURL),
                let text = String(data: data, encoding: .utf8)
            else {
                return ""
            }

            return text
        }
    }

    func clearLogs() {
        queue.sync {
            try? fileManager.removeItem(at: currentLogURL)
            try? fileManager.removeItem(at: previousLogURL)
            ensureCurrentFileExists()
        }
    }

    private func appendLine(_ line: String) {
        ensureCurrentFileExists()
        guard let data = line.data(using: .utf8) else {
            return
        }

        do {
            let fileHandle = try FileHandle(forWritingTo: currentLogURL)
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
            try fileHandle.close()
        } catch {
            // Keep this logger fail-safe; fallback to console only.
            print("AppLogger: append failed error=\(error.localizedDescription)")
        }
    }

    private func rotateIfNeeded(forAdditionalBytes additionalBytes: Int64) {
        ensureCurrentFileExists()
        let currentSize = (try? fileManager.attributesOfItem(atPath: currentLogURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard currentSize + additionalBytes > maxBytes else {
            return
        }

        try? fileManager.removeItem(at: previousLogURL)
        if fileManager.fileExists(atPath: currentLogURL.path) {
            try? fileManager.moveItem(at: currentLogURL, to: previousLogURL)
        }
        ensureCurrentFileExists()
    }

    private func ensureCurrentFileExists() {
        if !fileManager.fileExists(atPath: currentLogURL.path) {
            fileManager.createFile(atPath: currentLogURL.path, contents: Data(), attributes: nil)
        }
    }

    private var currentLogURL: URL {
        documentsDirectory.appending(path: currentFileName)
    }

    private var previousLogURL: URL {
        documentsDirectory.appending(path: previousFileName)
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
