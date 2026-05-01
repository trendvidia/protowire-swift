import Foundation

/// Envelope wraps an API response with transport metadata, an optional
/// success payload, and an optional application error.
public struct Envelope: Codable, Equatable {
    /// The status code of the response.
    public var status: Int32
    /// The transport error if the request failed at the transport layer.
    public var transportError: String?
    /// The actual data payload of the response.
    public var data: Data?
    /// The application-specific error if the request failed at the application layer.
    public var error: AppError?

    /// Initializes a new envelope.
    public init(status: Int32, transportError: String? = nil, data: Data? = nil, error: AppError? = nil) {
        self.status = status
        self.transportError = transportError
        self.data = data
        self.error = error
    }

    enum CodingKeys: Int, CodingKey {
        case status = 1
        case transportError = 2
        case data = 3
        case error = 4
    }
}

/// AppError represents an application-level error.
public struct AppError: Codable, Equatable {
    /// The application-specific error code.
    public var code: String
    /// A human-readable error message.
    public var message: String?
    /// Optional format arguments for the error message.
    public var args: [String]?
    /// A list of field-specific validation errors.
    public var details: [FieldError]?
    /// Optional metadata associated with the error.
    public var metadata: [String: String]?

    /// Initializes a new application error.
    public init(code: String, message: String? = nil, args: [String]? = nil, details: [FieldError]? = nil, metadata: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.args = args
        self.details = details
        self.metadata = metadata
    }

    enum CodingKeys: Int, CodingKey {
        case code = 1
        case message = 2
        case args = 3
        case details = 4
        case metadata = 5
    }
}

/// FieldError represents a validation error on a specific field.
public struct FieldError: Codable, Equatable {
    /// The name of the field that failed validation.
    public var field: String
    /// The error code for the validation failure.
    public var code: String
    /// A human-readable error message for the field.
    public var message: String?
    /// Optional format arguments for the field error message.
    public var args: [String]?

    /// Initializes a new field error.
    public init(field: String, code: String, message: String? = nil, args: [String]? = nil) {
        self.field = field
        self.code = code
        self.message = message
        self.args = args
    }

    enum CodingKeys: Int, CodingKey {
        case field = 1
        case code = 2
        case message = 3
        case args = 4
    }
}

// MARK: - Builders

extension Envelope {
    /// Creates a success envelope with the given status and raw data payload.
    public static func ok(status: Int32, data: Data?) -> Envelope {
        return Envelope(status: status, data: data)
    }

    /// Creates an error envelope.
    public static func err(status: Int32, code: String, message: String?, args: String...) -> Envelope {
        return Envelope(status: status, error: AppError(code: code, message: message, args: args))
    }

    /// Creates a transport-level error envelope.
    public static func transportErr(_ err: String) -> Envelope {
        return Envelope(status: 0, transportError: err)
    }
}

extension AppError {
    /// Creates an AppError with code, message, and optional format args.
    public init(code: String, message: String?, args: [String] = []) {
        self.code = code
        self.message = message
        self.args = args.isEmpty ? nil : args
    }

    /// Adds a field error to an AppError and returns it for chaining.
    @discardableResult
    public mutating func withField(field: String, code: String, message: String?, args: String...) -> AppError {
        var details = self.details ?? []
        details.append(FieldError(field: field, code: code, message: message, args: args.isEmpty ? nil : args))
        self.details = details
        return self
    }

    /// Adds a metadata key-value pair and returns the error for chaining.
    @discardableResult
    public mutating func withMeta(key: String, value: String) -> AppError {
        var metadata = self.metadata ?? [:]
        metadata[key] = value
        self.metadata = metadata
        return self
    }
}

// MARK: - Queries

extension Envelope {
    /// Reports whether the envelope represents a successful response.
    public var isOK: Bool {
        return (transportError == nil || transportError!.isEmpty) && error == nil
    }

    /// Reports whether the envelope has a transport-level error.
    public var isTransportError: Bool {
        return transportError != nil && !transportError!.isEmpty
    }

    /// Reports whether the envelope has an application-level error.
    public var isAppError: Bool {
        return error != nil
    }

    /// Returns the application error code, or empty string if no error.
    public var errorCode: String {
        return error?.code ?? ""
    }

    /// Returns field errors indexed by field name for easy lookup.
    public var fieldErrors: [String: FieldError]? {
        guard let details = error?.details else { return nil }
        var m: [String: FieldError] = [:]
        for fe in details {
            m[fe.field] = fe
        }
        return m
    }
}
