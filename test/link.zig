//! The tests' one way of linking a folder: on Windows a junction, which any account
//! makes, where a symbolic link needs SeCreateSymbolicLinkPrivilege; elsewhere a
//! symbolic link.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const windows = std.os.windows;

/// Links the folder at `link` to the folder at `target`, both absolute paths.
pub fn folder(io: Io, target: []const u8, link: []const u8) !void {
    std.debug.assert(std.fs.path.isAbsolute(target) and std.fs.path.isAbsolute(link));
    if (builtin.os.tag != .windows) return Io.Dir.cwd().symLink(io, target, link, .{ .is_directory = true });
    try junction(io, target, link);
}

const GENERIC_WRITE: windows.DWORD = 0x40000000;
const OPEN_EXISTING: windows.DWORD = 3;
const FILE_FLAG_OPEN_REPARSE_POINT: windows.DWORD = 0x00200000;
const FILE_FLAG_BACKUP_SEMANTICS: windows.DWORD = 0x02000000;

extern "kernel32" fn CreateFileW(
    lpFileName: windows.LPCWSTR,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn DeviceIoControl(
    hDevice: windows.HANDLE,
    dwIoControlCode: windows.DWORD,
    lpInBuffer: ?*const anyopaque,
    nInBufferSize: windows.DWORD,
    lpOutBuffer: ?*anyopaque,
    nOutBufferSize: windows.DWORD,
    lpBytesReturned: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

/// A REPARSE_DATA_BUFFER's header and its MountPointReparseBuffer's, before the names.
const MountPointHeader = extern struct {
    ReparseTag: windows.IO_REPARSE_TAG,
    ReparseDataLength: windows.USHORT,
    Reserved: windows.USHORT,
    SubstituteNameOffset: windows.USHORT,
    SubstituteNameLength: windows.USHORT,
    PrintNameOffset: windows.USHORT,
    PrintNameLength: windows.USHORT,
};

/// An empty folder at `link` made a mount point, NTFS's junction, naming `target`:
/// the substitute name its NT path `\??\C:\…`, the print name the path as given.
fn junction(io: Io, target: []const u8, link: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, link);
    var link_w: [windows.PATH_MAX_WIDE + 1]u16 = undefined;
    const link_len = try std.unicode.wtf8ToWtf16Le(&link_w, link);
    link_w[link_len] = 0;
    var print: [windows.PATH_MAX_WIDE]u16 = undefined;
    const print_len = try std.unicode.wtf8ToWtf16Le(&print, target);
    std.mem.replaceScalar(u16, print[0..print_len], std.mem.nativeToLittle(u16, '/'), std.mem.nativeToLittle(u16, '\\'));
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\??\\");
    var buffer: [windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 align(@alignOf(MountPointHeader)) = undefined;
    // Each name is counted in bytes without its NUL, and written with it.
    const substitute_bytes = (prefix.len + print_len) * 2;
    const print_bytes = print_len * 2;
    const names = buffer[@sizeOf(MountPointHeader)..];
    if (substitute_bytes + print_bytes + 4 > names.len) return error.NameTooLong;
    const header: MountPointHeader = .{
        .ReparseTag = .MOUNT_POINT,
        .ReparseDataLength = @intCast(8 + substitute_bytes + 2 + print_bytes + 2),
        .Reserved = 0,
        .SubstituteNameOffset = 0,
        .SubstituteNameLength = @intCast(substitute_bytes),
        .PrintNameOffset = @intCast(substitute_bytes + 2),
        .PrintNameLength = @intCast(print_bytes),
    };
    @memcpy(buffer[0..@sizeOf(MountPointHeader)], std.mem.asBytes(&header));
    @memcpy(names[0 .. prefix.len * 2], std.mem.sliceAsBytes(prefix));
    @memcpy(names[prefix.len * 2 ..][0..print_bytes], std.mem.sliceAsBytes(print[0..print_len]));
    @memset(names[substitute_bytes..][0..2], 0);
    @memcpy(names[substitute_bytes + 2 ..][0..print_bytes], std.mem.sliceAsBytes(print[0..print_len]));
    @memset(names[substitute_bytes + 2 + print_bytes ..][0..2], 0);
    const handle = CreateFileW(link_w[0..link_len :0], GENERIC_WRITE, 0, null, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, null);
    if (handle == windows.INVALID_HANDLE_VALUE) {
        std.debug.print("CreateFileW {s}: {t}\n", .{ link, windows.GetLastError() });
        return error.Unexpected;
    }
    defer windows.CloseHandle(handle);
    const length: windows.DWORD = @intCast(8 + header.ReparseDataLength);
    if (DeviceIoControl(handle, @bitCast(windows.CTL_CODE.SET_REPARSE_POINT), &buffer, length, null, 0, null, null).toBool()) return;
    std.debug.print("FSCTL_SET_REPARSE_POINT {s}: {t}\n", .{ link, windows.GetLastError() });
    return error.Unexpected;
}

test "a folder linked is read back as a link to its target, and deleting the link leaves the target" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/inner", .data = "inner" });
    const where = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(where);
    const target = try std.fs.path.join(a, &.{ where, "real" });
    defer a.free(target);
    const link = try std.fs.path.join(a, &.{ where, "link" });
    defer a.free(link);
    try folder(io, target, link);
    try std.testing.expectEqual(.sym_link, (try tmp.dir.statFile(io, "link", .{ .follow_symlinks = false })).kind);
    var read: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(target, read[0..try tmp.dir.readLink(io, "link", &read)]);
    const through = try tmp.dir.readFileAlloc(io, "link/inner", a, .limited(64));
    defer a.free(through);
    try std.testing.expectEqualStrings("inner", through);
    try tmp.dir.deleteTree(io, "link");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "link", .{}));
    const kept = try tmp.dir.readFileAlloc(io, "real/inner", a, .limited(64));
    defer a.free(kept);
    try std.testing.expectEqualStrings("inner", kept);
}
