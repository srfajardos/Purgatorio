//
//  AtomicJournaler.swift
//  Purgatorio
//
//  v3.0 — WAL Rediseñado para Two-Phase Commit
//

import Foundation
import os.log

public actor AtomicJournaler {
    
    private let logURL: URL
    private let albumIDURL: URL
    private var writeHandle: FileHandle?
    private let logger = Logger(subsystem: "com.purgatorio.app", category: "AtomicJournaler")
    
    public init(logURL: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        
        if let logURL {
            self.logURL = logURL
        } else {
            self.logURL = appSupport.appendingPathComponent("shredder_wal.purg")
        }
        self.albumIDURL = appSupport.appendingPathComponent("purgatorio_album_id.txt")
    }
    
    /// Convierta el string a Data y haga un `.write()` directo. O(1).
    public func appendRecord(identifier: String) {
        guard let data = identifier.data(using: .utf8) else { return }
        var length = UInt32(data.count).littleEndian
        let handle = getOrCreateHandle()
        
        handle.write(Data(bytes: &length, count: 4))
        handle.write(data)
        handle.write(Data([0x0A])) // newline delim.
        handle.synchronizeFile()
    }
    
    /// Lectura Pura (Fase 1 del 2PC): No purga el archivo.
    public func recoverState() -> [String] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return [] }
        
        var entries: [String] = []
        var offset = 0
        
        while offset + 4 < data.count {
            let lengthData = data[offset ..< offset + 4]
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            offset += 4
            
            let end = offset + Int(length)
            guard end <= data.count else { break }
            
            let payload = data[offset ..< end]
            if let id = String(data: payload, encoding: .utf8) {
                entries.append(id)
            }
            offset = end + 1 // salta newline
        }
        return entries
    }

    /// Purgado del WAL (Fase 2 del 2PC): Solo tras éxito de PHPhotoLibrary.
    public func clearWAL() {
        closeHandle()
        try? Data().write(to: logURL, options: .atomic)
        logger.info("WAL purgado exitosamente tras confirmación de Photos.")
    }
    
    public func saveAlbumID(_ albumID: String) {
        try? albumID.write(to: albumIDURL, atomically: true, encoding: .utf8)
    }
    
    public func loadAlbumID() -> String? {
        guard FileManager.default.fileExists(atPath: albumIDURL.path) else { return nil }
        let id = try? String(contentsOf: albumIDURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }
    
    public static let shared = AtomicJournaler()
    
    private func getOrCreateHandle() -> FileHandle {
        if let handle = writeHandle { return handle }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try! FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        writeHandle = handle
        return handle
    }
    
    private func closeHandle() {
        try? writeHandle?.close()
        writeHandle = nil
    }
}
