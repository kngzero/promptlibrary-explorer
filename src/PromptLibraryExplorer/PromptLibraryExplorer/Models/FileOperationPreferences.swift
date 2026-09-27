import AppKit

/// What to do when an incoming file's name is already taken in the destination.
enum DuplicateNamePolicy: String, CaseIterable, Identifiable {
    case keepBoth
    case skip
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepBoth: return "Keep both"
        case .skip: return "Skip the incoming file"
        case .replace: return "Replace the existing file"
        }
    }

    var explanation: String {
        switch self {
        case .keepBoth:
            return "Numbers the incoming file, so sunset.png arrives as sunset 2.png."
        case .skip:
            return "Leaves the existing file alone and reports how many were skipped."
        case .replace:
            return "Moves the existing file to the Trash, then puts the incoming one in its place. Undo restores the incoming file's original location but does not recover the replaced file from the Trash."
        }
    }
}

/// Whether dragging files out of the app hands other apps a copy or the original.
enum ExternalDragOperation: String, CaseIterable, Identifiable {
    case copy
    case move

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: return "Copy"
        case .move: return "Move"
        }
    }

    var explanation: String {
        switch self {
        case .copy:
            return "The file stays in your library and the other app receives a duplicate."
        case .move:
            return "The file leaves your library. Finder and most apps honour this; some accept only a copy regardless."
        }
    }

    var dragOperation: NSDragOperation {
        switch self {
        case .copy: return .copy
        case .move: return .move
        }
    }
}
