import SwiftUI

public enum ValidationState: Equatable {
    case normal
    case success(message: String? = nil)
    case error(message: String? = nil)

    public var color: Color {
        switch self {
        case .normal: return Color.separatorLine
        case .success: return Color.success
        case .error: return Color.destructive
        }
    }

    public var message: String? {
        switch self {
        case .normal: return nil
        case .success(let m): return m
        case .error(let m): return m
        }
    }

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var isNormal: Bool {
        if case .normal = self { return true }
        return false
    }
}


