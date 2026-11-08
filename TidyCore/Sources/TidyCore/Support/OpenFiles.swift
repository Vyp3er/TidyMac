import Darwin
import Foundation

/// Tells whether a file is currently opened by any process of this user.
public protocol OpenFilesProvider: Sendable {
    func openPaths() -> Set<String>
}

/// Enumerates open vnodes of all processes this user may inspect (same mechanism as `lsof`).
public struct ProcOpenFilesProvider: OpenFilesProvider {
    public init() {}

    public func openPaths() -> Set<String> {
        var result = Set<String>()
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return result }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, byteCount) }
        guard count > 0 else { return result }

        for pid in pids.prefix(Int(count)) where pid > 0 {
            let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bufferSize > 0 else { continue }
            let fdStride = MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / fdStride + 1)
            let fdBytes = Int32(fds.count * fdStride)
            let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, fdBytes) }
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / fdStride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
                let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size)
                guard r == size else { continue }
                let path = withUnsafeBytes(of: info.pvip.vip_path) { raw -> String in
                    let chars = raw.bindMemory(to: CChar.self)
                    guard let base = chars.baseAddress else { return "" }
                    return String(cString: base)
                }
                if !path.isEmpty { result.insert(path) }
            }
        }
        return result
    }
}

/// Fixed set, used by tests.
public struct StaticOpenFilesProvider: OpenFilesProvider {
    public var paths: Set<String>
    public init(_ paths: Set<String> = []) { self.paths = paths }
    public func openPaths() -> Set<String> { paths }
}

public enum OpenFileCheck {
    /// True if the file (or anything inside a folder) appears in `open`, or an Office lock file exists.
    public static func isInUse(_ url: URL, open: Set<String>) -> Bool {
        let path = PathUtil.path(url)
        let resolved = PathUtil.path(url.resolvingSymlinksInPath())
        if open.contains(path) || open.contains(resolved) { return true }
        if PathUtil.isDirectory(url) {
            let prefixes = [path + "/", resolved + "/"]
            if open.contains(where: { p in prefixes.contains { p.hasPrefix($0) } }) { return true }
        }
        // Microsoft Office / LibreOffice lock files next to an open document.
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let lockNames = ["~$" + name, ".~lock." + name + "#"]
        if name.count > 2 {
            let shortened = "~$" + String(name.dropFirst(2))
            if PathUtil.exists(dir.appendingPathComponent(shortened)) { return true }
        }
        return lockNames.contains { PathUtil.exists(dir.appendingPathComponent($0)) }
    }
}
