import XCTest
import Foundation
import Darwin
import CoreGraphics
@testable import PhotonsCore

/// 486 — saving XMP must not change the file's **creation date**.
///
/// The slot-reuse path writes only the changed bytes into the existing inode, so `stat -f %SB`
/// (birth), `ATTR_CMN_ADDEDTIME` (Date Added), the permission bits and every extended attribute stay
/// exactly where they were. The append path has to replace the file atomically; it puts birth,
/// permissions, extended attributes and ACL back, but Date Added cannot be restored — no public API
/// sets it.
final class DNGXMPMetadata486Tests: XCTestCase {

    private var source: URL {
        let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
        return URL(fileURLWithPath: env ?? NSString(string: "~/Desktop/test/L1030433.dng")
            .expandingTildeInPath)
    }

    private func copyOfSource() throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("dng486-\(UUID().uuidString).dng")
        try FileManager.default.copyItem(at: source, to: dst)
        addTeardownBlock { try? FileManager.default.removeItem(at: dst) }
        return dst
    }

    private func journal() -> DNGXMPJournal {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dng486-journal-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return DNGXMPJournal(directory: dir)
    }

    // MARK: - kernel stamps

    private struct Stamp {
        let inode: UInt64
        let birth: Date?
        let added: timespec?
        let size: Int
        let permissions: Int
        let xattrs: [String: Data]
    }

    private func stamp(_ url: URL) throws -> Stamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            birth: attributes[.creationDate] as? Date,
            added: addedTime(at: url.path),
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
            xattrs: extendedAttributes(at: url.path))
    }

    /// `ATTR_CMN_ADDEDTIME` — the kernel value behind `kMDItemDateAdded`. `stat` does not expose it,
    /// and there is no setter, so an in-place write is the only way to keep it.
    private func addedTime(at path: String) -> timespec? {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &list, &buffer, buffer.count, 0) == 0 else { return nil }
        var value = timespec()
        withUnsafeMutableBytes(of: &value) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(
                    rebasing: source[4..<(4 + MemoryLayout<timespec>.size)]))
            }
        }
        return value
    }

    private func extendedAttributes(at path: String) -> [String: Data] {
        let size = listxattr(path, nil, 0, 0)
        guard size > 0 else { return [:] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(path, &buffer, size, 0) == size else { return [:] }

        var names: [String] = []
        var current = ""
        for byte in buffer {
            if byte == 0 {
                if !current.isEmpty { names.append(current); current = "" }
            } else {
                current.append(Character(UnicodeScalar(UInt8(bitPattern: byte))))
            }
        }

        var values: [String: Data] = [:]
        for name in names {
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length >= 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            guard getxattr(path, name, &bytes, length, 0, 0) == length else { continue }
            values[name] = Data(bytes)
        }
        return values
    }

    private func exiftoolMetadata(_ url: URL) -> String? {
        let candidates = ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-DateTimeOriginal", "-CreateDate", "-XMP:CreateDate", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func assertSameFileIdentity(_ before: Stamp, _ after: Stamp,
                                        _ context: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(after.inode, before.inode, "\(context)：inode 变了", file: file, line: line)
        XCTAssertEqual(after.birth, before.birth, "\(context)：创建日期（%SB）变了", file: file, line: line)
        XCTAssertEqual(after.added?.tv_sec, before.added?.tv_sec,
                       "\(context)：Date Added 的秒变了", file: file, line: line)
        XCTAssertEqual(after.added?.tv_nsec, before.added?.tv_nsec,
                       "\(context)：Date Added 的纳秒变了", file: file, line: line)
        XCTAssertEqual(after.permissions, before.permissions,
                       "\(context)：权限位变了", file: file, line: line)
        XCTAssertEqual(after.xattrs, before.xattrs,
                       "\(context)：扩展属性变了", file: file, line: line)
    }

    // MARK: - ① slot reuse: inode, birth and Date Added survive

    func testSlotReuseKeepsInodeBirthDateAddedAndExifTimestamps() throws {
        let url = try copyOfSource()
        let j = journal()
        let originalExif = exiftoolMetadata(url)
        let document = #"{"schemaVersion":12,"light":{"exposure":0.75},"masks":[{"name":"渐变"}]}"#

        _ = try DNGXMP.writeDocument(document, to: url, journal: j)
        let before = try stamp(url)

        let second = try DNGXMP.writeDocument(document, to: url, journal: j)
        XCTAssertTrue(second.reusedSlot, "第二次同长度写入必须复用槽位，实际 \(second)")
        XCTAssertEqual(second.appendedBytes, 0)

        let after = try stamp(url)
        assertSameFileIdentity(before, after, "槽位复用")
        XCTAssertEqual(after.size, before.size, "槽位复用不许改文件大小")

        if let originalExif {
            XCTAssertEqual(exiftoolMetadata(url), originalExif,
                           "DateTimeOriginal / CreateDate / XMP:CreateDate 必须不变")
        }

        print("486 槽位复用：inode \(before.inode) → \(after.inode) · birth \(before.birth.map(String.init(describing:)) ?? "nil") · size \(before.size) → \(after.size)")
    }

    // MARK: - ② append: atomic, then birth/permissions/xattrs restored

    func testAppendPathRestoresBirthPermissionsAndExtendedAttributes() throws {
        let url = try copyOfSource()
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let attribute = "user.photons486"
        let value = Data("kept".utf8)
        XCTAssertEqual(value.withUnsafeBytes {
            setxattr(url.path, attribute, $0.baseAddress, value.count, 0, 0)
        }, 0, "测试准备：写一个扩展属性")

        let before = try stamp(url)
        // Big enough that the merged packet cannot fit the existing tag-700 slot.
        let document = #"{"blob":""# + String(repeating: "x", count: 64 * 1024) + #""}"#
        let outcome = try DNGXMP.writeDocument(document, to: url, journal: journal())
        XCTAssertFalse(outcome.reusedSlot, "这个文档必须放不进原槽位，才能走 atomic 追加路径")
        XCTAssertGreaterThan(outcome.appendedBytes, 0)

        let after = try stamp(url)
        XCTAssertNotEqual(after.inode, before.inode, "atomic 追加换 inode 是这条路径的预期")
        XCTAssertEqual(after.birth, before.birth, "创建日期必须被还原")
        XCTAssertEqual(after.permissions, 0o640, "权限位必须被还原")
        XCTAssertEqual(after.xattrs, before.xattrs, "扩展属性必须被还原")
        XCTAssertTrue(try XCTUnwrap(DNGXMP.documentString(at: url)).hasPrefix(#"{"blob":""#))

        print("486 追加路径：inode \(before.inode) → \(after.inode)（接受）· birth 已还原 · 权限/扩展属性已还原 · Date Added 在这条路径上无法还原")
    }

    // MARK: - ③ thumbnail replacement uses the same two paths

    func testThumbnailReuseKeepsInodeBirthAndDateAdded() throws {
        let url = try copyOfSource()
        let target = ImageSize(width: 1920, height: 1280)
        let jpeg = try XCTUnwrap(DNGThumbnail.jpegData(from: solidImage(width: 3000, height: 2000),
                                                       targetSize: target))
        _ = try DNGThumbnail.write(jpeg, size: target, to: url, journal: journal())
        let before = try stamp(url)

        let second = try DNGThumbnail.write(jpeg, size: target, to: url, journal: journal())
        XCTAssertTrue(second.replacedInPlace, "第二次同一份 JPEG 必须原位覆盖，实际 \(second)")

        let after = try stamp(url)
        assertSameFileIdentity(before, after, "缩略图原位覆盖")
        XCTAssertEqual(after.size, before.size)
        print("486 缩略图：inode \(before.inode) → \(after.inode) · birth 未动 · Date Added 未动")
    }

    private func solidImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - ④ reverse gate

    /// The inode/birth assertions above can only catch the old behaviour if an atomic replace really
    /// moves them. This is that control: put `data.write(.atomic)` back and the same stamp changes.
    func testAtomicReplaceMovesInodeAndBirthSoTheAssertionIsReal() throws {
        let url = try copyOfSource()
        let before = try stamp(url)
        let data = try Data(contentsOf: url)
        try data.write(to: url, options: .atomic)
        let after = try stamp(url)
        XCTAssertNotEqual(after.inode, before.inode, "atomic 写必须换 inode（反向门）")
        XCTAssertNotEqual(after.birth, before.birth, "atomic 写会把 birth 改成当下（反向门）")
        print("486 反向门：atomic ⇒ inode \(before.inode) → \(after.inode)，birth 变了")
    }
}
