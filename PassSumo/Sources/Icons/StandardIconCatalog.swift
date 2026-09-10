import Foundation

// MARK: - Standard KDBX icons
//
// KDBX stores a built-in icon as a bare integer: `IconID`, an index into the icon set KeePass has
// shipped since 1.x. The artwork behind those indices is KeePass's, under licences this repo has
// not cleared, so pass-sumo does not ship it — it draws an SF Symbol for each index instead
// (issue #89). Nothing about interop changes: the integer in the file is what every other client
// reads, and this table only decides what WE paint for it.
//
// This file is data, deliberately. It has no dependency on SwiftUI or AppKit and lives outside
// `Sources/UI` so the mapping can be reviewed, tested and reused without dragging a view in.

/// The 69 built-in KeePass icon indices (0…68) mapped to SF Symbol names.
///
/// The KeePass name on each line is the identifier from KeePass's own `PwIcon` enumeration, and it
/// is there so a human can check the mapping without opening KeePass: the code cannot verify that
/// `banknote` is a sensible drawing of "Homebanking", only that the symbol exists.
///
/// Two things about the choices:
///
/// - **Outline symbols, not `.fill` ones.** That is the idiom already in the app — the sidebar
///   draws `folder`, `trash` and `tray.full` — and index 43 and index 48 have to keep producing
///   exactly today's recycle-bin and folder appearance, or adopting this table would visibly
///   change a screen nobody asked to change. `folder.fill` at index 49 is the single deliberate
///   exception: SF Symbols has no open-folder glyph, and the filled variant is the only way to
///   tell "FolderOpen" apart from "Folder" one row above it.
/// - **Some are approximations, and that is accepted.** KeePass's set is a Windows-desktop icon
///   set from 2003; there is no SF Symbol for "Tux", and none that combines an envelope with a
///   magnifying glass. Where no faithful symbol exists the closest recognisable one is used rather
///   than a blank, because an icon that reads as roughly the right thing is more useful in a
///   picker than a grid of question marks.
enum StandardIconCatalog {
    /// Indexed by icon id: `symbolNames[43]` is what KeePass calls `TrashBin`.
    ///
    /// An array rather than a dictionary because the ids are a dense 0…68 range with no gaps, so
    /// the position IS the key — which also makes a missing or duplicated line show up as a wrong
    /// `count`, caught by `StandardIconCatalogTests`.
    static let symbolNames: [String] = [
        "key",                                      //  0 Key
        "globe",                                    //  1 World
        "exclamationmark.triangle",                 //  2 Warning
        "server.rack",                              //  3 NetworkServer
        "folder.badge.plus",                        //  4 MarkedDirectory
        "person.bubble",                            //  5 UserCommunication
        "puzzlepiece.extension",                    //  6 Parts
        "doc.plaintext",                            //  7 Notepad
        "network",                                  //  8 WorldSocket
        "person.text.rectangle",                    //  9 Identity
        "doc.text",                                 // 10 PaperReady
        "camera",                                   // 11 Digicam
        "dot.radiowaves.right",                     // 12 IRCommunication
        "key.2.on.ring",                            // 13 MultiKeys
        "bolt",                                     // 14 Energy
        "scanner",                                  // 15 Scanner
        "globe.badge.chevron.backward",             // 16 WorldStar
        "opticaldisc",                              // 17 CDRom
        "display",                                  // 18 Monitor
        "envelope",                                 // 19 EMail
        "gearshape",                                // 20 Configuration
        "list.clipboard",                           // 21 ClipboardReady
        "doc.badge.plus",                           // 22 PaperNew
        "menubar.dock.rectangle",                   // 23 Screen
        "bolt.shield",                              // 24 EnergyCareful
        "tray.full",                                // 25 EMailBox
        "externaldrive",                            // 26 Disk
        "internaldrive",                            // 27 Drive
        "doc.questionmark",                         // 28 PaperQ
        "lock.laptopcomputer",                      // 29 TerminalEncrypted
        "terminal",                                 // 30 Console
        "printer",                                  // 31 Printer
        "square.grid.2x2",                          // 32 ProgramIcons
        "play",                                     // 33 Run
        "wrench.and.screwdriver",                   // 34 Settings
        "globe.desk",                               // 35 WorldComputer
        "doc.zipper",                               // 36 Archive
        "banknote",                                 // 37 Homebanking
        "externaldrive.connected.to.line.below",    // 38 DriveWindows
        "clock",                                    // 39 Clock
        "magnifyingglass",                          // 40 EMailSearch
        "flag",                                     // 41 PaperFlag
        "memorychip",                               // 42 Memory
        "trash",                                    // 43 TrashBin — the recycle bin; see below
        "note.text",                                // 44 Note
        "xmark.octagon",                            // 45 Expired
        "info.circle",                              // 46 Info
        "shippingbox",                              // 47 Package
        "folder",                                   // 48 Folder — the group default; see below
        "folder.fill",                              // 49 FolderOpen
        "archivebox",                               // 50 FolderPackage
        "lock.open",                                // 51 LockOpen
        "lock.doc",                                 // 52 PaperLocked
        "checkmark.circle",                         // 53 Checked
        "pencil",                                   // 54 Pen
        "photo",                                    // 55 Thumbnail
        "book",                                     // 56 Book
        "list.bullet",                              // 57 List
        "person.badge.key",                         // 58 UserKey
        "hammer",                                   // 59 Tool
        "house",                                    // 60 Home
        "star",                                     // 61 Star
        "pc",                                       // 62 Tux
        "signature",                                // 63 Feather
        "apple.logo",                               // 64 Apple
        "text.book.closed",                         // 65 Wiki
        "dollarsign.circle",                        // 66 Money
        "seal",                                     // 67 Certificate
        "candybarphone",                            // 68 BlackBerry
    ]

    /// The SF Symbol for a KDBX icon index, or `nil` when the file names an index this set does
    /// not have.
    ///
    /// `nil` rather than a substituted default on purpose: the sensible substitute differs by
    /// call site — an entry falls back to the key, a group to the folder — and only the caller
    /// knows which it is. An out-of-range index is not hypothetical: `IconID` is a 32-bit integer
    /// in the format, KeePass has extended the set before, and whatever a file says is written
    /// back unchanged (see `VaultEntry.iconID`), so a value we cannot draw still has to survive.
    static func symbolName(for iconID: UInt32) -> String? {
        guard iconID < symbolNames.count else { return nil }
        return symbolNames[Int(iconID)]
    }
}
