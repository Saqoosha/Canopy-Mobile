import Foundation

/// Path helpers and validation for the Mac control API's folder verbs (`browse_dir`, `create_folder`).
enum RemoteFolder {
    /// Joins a parent directory path and a single path segment (not a nested relative path).
    static func join(base: String, name: String) -> String {
        if base == "/" { return "/\(name)" }
        return (base as NSString).appendingPathComponent(name)
    }

    /// Returns a user-visible reason when the name is not acceptable locally, before hitting the Mac.
    static func validateName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a folder name." }
        if name == "." || name == ".." { return "That name is not allowed." }
        if name.contains("/") || name.contains("\0") { return "Folder names can't include /." }
        if name.count > 255 { return "Folder name is too long." }
        return nil
    }

    /// Reads the created directory from a `create_folder` result.
    static func createdPath(from result: [String: Any]) -> String? {
        guard let path = result["path"] as? String, !path.isEmpty else { return nil }
        return path
    }

    /// Maps control errors from folder creation into short copy for the sheet.
    static func createErrorMessage(_ error: Error) -> String {
        if let control = error as? MachineControl.ControlError {
            switch control {
            case .closed, .notReachable:
                return "Lost connection to the Mac. Close this sheet and try again."
            case .updateCanopy, .noServer, .versionMismatch:
                return control.message
            case .passwordRejected:
                return control.message
            case .failed(let text):
                return mapFailed(text)
            }
        }
        return MachineControl.ControlError.notReachable.message
    }

    private static func mapFailed(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("exist") {
            return "A folder with that name already exists here."
        }
        if lower.contains("permission") || lower.contains("denied") || lower.contains("not permitted") {
            return "Canopy can't create folders in this directory."
        }
        if lower.contains("unknown verb") || lower.contains("unsupported verb") || lower.contains("not supported") {
            return "Update Canopy on that Mac to create folders from your iPhone."
        }
        if lower.contains("invalid") && lower.contains("name") {
            return text
        }
        return text
    }
}

extension MachineControl {
    /// Asks the Mac to create `name` inside `parentPath`. Requires Canopy's `create_folder` control verb.
    func createFolder(parentPath: String, name: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await request("create_folder", ["path": parentPath, "name": trimmed])
        guard let path = RemoteFolder.createdPath(from: result) else {
            throw ControlError.failed("Empty response")
        }
        return path
    }
}
