import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Errore POSIX con contesto, con messaggio in italiano.
public struct DiskIOError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public let operation: String
    public let path: String

    public init(code: Int32, operation: String, path: String) {
        self.code = code
        self.operation = operation
        self.path = path
    }

    /// Errori dopo i quali ha senso fermare tutta la destinazione (disco pieno, scollegato, in sola lettura, I/O).
    public var isFatalForDestination: Bool {
        switch code {
        case ENOSPC, EDQUOT, EIO, ENXIO, ENODEV, ENOTCONN, EROFS, ESTALE, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH:
            return true
        default:
            return false
        }
    }

    public var description: String {
        let reason: String
        switch code {
        case ENOSPC, EDQUOT: reason = "spazio insufficiente sul disco"
        case EIO: reason = "errore di input/output (disco o scheda non leggibile, forse scollegato)"
        case ENXIO, ENODEV, ENOTCONN, ESTALE: reason = "il disco non è più disponibile (scollegato?)"
        case ENOENT: reason = "file o cartella non trovato (disco scollegato o file spostato?)"
        case EACCES, EPERM: reason = "permesso negato"
        case EROFS: reason = "volume in sola lettura"
        case ENAMETOOLONG: reason = "nome file troppo lungo"
        case EMFILE, ENFILE: reason = "troppi file aperti"
        default: reason = String(cString: strerror(code)) + " (errno \(code))"
        }
        return "\(operation) «\(path)»: \(reason)"
    }
}

public enum DiskIO {
    public static let pageSize = 4096

    // MARK: Buffer allineati

    public static func allocateBuffer(size: Int) -> UnsafeMutableRawPointer {
        var ptr: UnsafeMutableRawPointer?
        let rc = posix_memalign(&ptr, pageSize, size)
        precondition(rc == 0 && ptr != nil, "posix_memalign fallita")
        return ptr!
    }

    // MARK: Apertura

    /// Apre un file in SOLA LETTURA. Con `uncached` la lettura bypassa la cache di macOS (F_NOCACHE).
    public static func openForReading(path: String, uncached: Bool) throws -> Int32 {
        let fd = open(path, O_RDONLY)
        if fd < 0 { throw DiskIOError(code: errno, operation: "Apertura in lettura", path: path) }
        if uncached { disableCaching(fd: fd) }
        return fd
    }

    /// Crea (o tronca) un file di destinazione. F_NOCACHE evita che i dati scritti restino in cache,
    /// così la successiva verifica legge davvero dal disco.
    public static func openForWriting(path: String) throws -> Int32 {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd < 0 { throw DiskIOError(code: errno, operation: "Creazione file", path: path) }
        disableCaching(fd: fd)
        return fd
    }

    public static func disableCaching(fd: Int32) {
        #if canImport(Darwin)
        _ = fcntl(fd, F_NOCACHE, 1)
        #else
        _ = posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED)
        #endif
    }

    /// Su Linux (usato solo per i test) scarta dalla cache le pagine già lette.
    @inline(__always)
    static func dropCachedPages(fd: Int32, offset: Int64, length: Int) {
        #if !canImport(Darwin)
        _ = posix_fadvise(fd, off_t(offset), off_t(length), POSIX_FADV_DONTNEED)
        #endif
    }

    // MARK: Lettura / scrittura complete

    /// Legge fino a `count` byte; restituisce meno solo a fine file.
    public static func readFully(fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int, path: String) throws -> Int {
        var total = 0
        while total < count {
            let n = read(fd, buffer + total, count - total)
            if n < 0 {
                if errno == EINTR { continue }
                throw DiskIOError(code: errno, operation: "Lettura", path: path)
            }
            if n == 0 { break }
            total += n
        }
        return total
    }

    public static func writeFully(fd: Int32, from buffer: UnsafeRawPointer, count: Int, path: String) throws {
        var total = 0
        while total < count {
            let n = write(fd, buffer + total, count - total)
            if n < 0 {
                if errno == EINTR { continue }
                throw DiskIOError(code: errno, operation: "Scrittura", path: path)
            }
            if n == 0 { throw DiskIOError(code: EIO, operation: "Scrittura", path: path) }
            total += n
        }
    }

    /// Forza i dati su disco. Su macOS usa F_FULLFSYNC (svuota anche la cache hardware del disco).
    /// Solo `fsync`: i dati arrivano al disco ma non è garantito lo svuotamento della sua cache hardware. Va sempre seguito da `flushDeviceCache`
    /// prima di rileggere il file per la verifica (serve a non pagare un F_FULLFSYNC per ogni file piccolo).
    public static func syncData(fd: Int32, path: String) throws {
        if fsync(fd) != 0 { throw DiskIOError(code: errno, operation: "Sincronizzazione su disco", path: path) }
    }

    /// Svuota la cache hardware del disco su cui si trova `path` (F_FULLFSYNC su un file esistente, aperto in sola lettura).
    public static func flushDeviceCache(path: String) throws {
        let fd = open(path, O_RDONLY)
        if fd < 0 { throw DiskIOError(code: errno, operation: "Sincronizzazione su disco", path: path) }
        defer { close(fd) }
        try flushToDisk(fd: fd, path: path)
    }

    public static func flushToDisk(fd: Int32, path: String) throws {
        #if canImport(Darwin)
        if fcntl(fd, F_FULLFSYNC) == -1 {
            // Alcuni file system non supportano F_FULLFSYNC: ripiego su fsync.
            if fsync(fd) != 0 { throw DiskIOError(code: errno, operation: "Sincronizzazione su disco", path: path) }
        }
        #else
        if fsync(fd) != 0 { throw DiskIOError(code: errno, operation: "Sincronizzazione su disco", path: path) }
        #endif
    }

    // MARK: Spazio libero

    /// Spazio disponibile (byte) sul volume che contiene `path` (o il suo antenato esistente più vicino).
    public static func availableSpace(atOrAbove path: String) -> Int64? {
        var current = path
        while true {
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: current),
               let free = attrs[.systemFreeSize] as? NSNumber {
                return free.int64Value
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    // MARK: Date

    public struct FileTimes {
        public var modification: Date
        public var creation: Date?
        public init(modification: Date, creation: Date?) {
            self.modification = modification
            self.creation = creation
        }
    }

    /// Imposta data di modifica (e, su macOS, di creazione) mantenendo la precisione al nanosecondo.
    public static func applyTimes(_ times: FileTimes, toPath path: String) throws {
        #if canImport(Darwin)
        if let c = times.creation {
            try? FileManager.default.setAttributes([.creationDate: c], ofItemAtPath: path)
        }
        #endif
        let ti = times.modification.timeIntervalSince1970
        var sec = ti.rounded(.down)
        var nsec = ((ti - sec) * 1_000_000_000).rounded()
        if nsec >= 1_000_000_000 { sec += 1; nsec = 0 }
        let ts = timespec(tv_sec: Int(sec), tv_nsec: Int(nsec))
        var arr = [ts, ts]
        if utimensat(AT_FDCWD, path, &arr, 0) != 0 {
            throw DiskIOError(code: errno, operation: "Impostazione date", path: path)
        }
    }

    /// Informazioni di un file/cartella senza seguire i link simbolici.
    public struct StatInfo {
        public var isDirectory: Bool
        public var isRegular: Bool
        public var isSymlink: Bool
        public var size: Int64
        public var times: FileTimes
    }

    public static func lstatInfo(path: String) throws -> StatInfo {
        var st = stat()
        if lstat(path, &st) != 0 { throw DiskIOError(code: errno, operation: "Lettura attributi", path: path) }
        let mode = st.st_mode & S_IFMT
        #if canImport(Darwin)
        let m = st.st_mtimespec
        let b = st.st_birthtimespec
        let creation: Date? = Date(timeIntervalSince1970: TimeInterval(b.tv_sec) + TimeInterval(b.tv_nsec) / 1e9)
        #else
        let m = st.st_mtim
        let creation: Date? = nil
        #endif
        let mod = Date(timeIntervalSince1970: TimeInterval(m.tv_sec) + TimeInterval(m.tv_nsec) / 1e9)
        return StatInfo(isDirectory: mode == S_IFDIR, isRegular: mode == S_IFREG, isSymlink: mode == S_IFLNK,
                        size: Int64(st.st_size), times: FileTimes(modification: mod, creation: creation))
    }
}
