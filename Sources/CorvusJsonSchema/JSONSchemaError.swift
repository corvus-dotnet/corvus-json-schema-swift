import CCorvusJsonSchema

/// Why a call failed, from the C library's status and message.
public enum JSONSchemaError: Error, Sendable, Equatable, CustomStringConvertible {
    /// An argument the library rejected.
    case invalidArgument(String)
    /// Text that is not valid UTF-8, with the byte offset where it stops being so.
    case invalidUTF8(String, offset: Int)
    /// Text that is not valid JSON, with the byte offset of the error.
    case invalidJSON(String, offset: Int)
    /// A schema that does not compile: invalid, or with a reference that cannot be resolved.
    case compilationFailed(String)
    /// An evaluation that recursed in place beyond the maximum depth.
    case depthExceeded(String)
    /// A bug in the library.
    case internalError(String)

    public var description: String {
        switch self {
        case .invalidArgument(let m): return "invalid argument: \(m)"
        case .invalidUTF8(let m, let offset): return "invalid UTF-8 at byte \(offset): \(m)"
        case .invalidJSON(let m, let offset): return "invalid JSON at byte \(offset): \(m)"
        case .compilationFailed(let m): return "compilation failed: \(m)"
        case .depthExceeded(let m): return "depth exceeded: \(m)"
        case .internalError(let m): return "internal error: \(m)"
        }
    }
}

/// Throws the error a status stands for, with the message (and offset) the library recorded for this thread.
func check(_ status: cjs_status) throws {
    if status == cjs_status(CJS_OK) {
        return
    }
    let message = string(cjs_last_error_message())
    let offset = Int(cjs_last_error_offset())
    switch Int32(status) {
    case CJS_INVALID_ARGUMENT: throw JSONSchemaError.invalidArgument(message)
    case CJS_INVALID_UTF8: throw JSONSchemaError.invalidUTF8(message, offset: offset)
    case CJS_INVALID_JSON: throw JSONSchemaError.invalidJSON(message, offset: offset)
    case CJS_COMPILATION_FAILED: throw JSONSchemaError.compilationFailed(message)
    case CJS_DEPTH_EXCEEDED: throw JSONSchemaError.depthExceeded(message)
    default: throw JSONSchemaError.internalError(message)
    }
}
