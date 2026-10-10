import Foundation
import SyncContracts

/// Small, lossless JSON value used by the declarative REST adapter. Keeping provider
/// payloads dynamic avoids a provider-specific DTO for every integration while all
/// canonical values still pass through typed `RemoteList`/`RemoteTask`.
public enum RESTJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RESTJSONValue])
    case object([String: RESTJSONValue])

    public init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decodeNil(), value { self = .null; return }
        if let value = try? decoder.singleValueContainer().decode(Bool.self) { self = .bool(value); return }
        if let value = try? decoder.singleValueContainer().decode(Int.self) { self = .number(Double(value)); return }
        if let value = try? decoder.singleValueContainer().decode(Double.self) { self = .number(value); return }
        if let value = try? decoder.singleValueContainer().decode(String.self) { self = .string(value); return }
        if let value = try? decoder.singleValueContainer().decode([RESTJSONValue].self) { self = .array(value); return }
        self = .object(try decoder.singleValueContainer().decode([String: RESTJSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    func value(at path: RESTJSONPath) -> RESTJSONValue? {
        var current = self
        for component in path.components {
            guard case let .object(object) = current, let next = object[component] else { return nil }
            current = next
        }
        return current
    }

    mutating func set(_ value: RESTJSONValue, at path: RESTJSONPath) {
        let components = path.components
        guard !components.isEmpty else { self = value; return }
        set(value, components: components[...])
    }

    private mutating func set(_ value: RESTJSONValue, components: ArraySlice<String>) {
        guard let head = components.first else { self = value; return }
        var object: [String: RESTJSONValue]
        if case let .object(existing) = self { object = existing } else { object = [:] }
        var child = object[head] ?? .object([:])
        child.set(value, components: components.dropFirst())
        object[head] = child
        self = .object(object)
    }

    func string() -> String? {
        if case let .string(value) = self { return value }
        return nil
    }

    func bool() -> Bool? {
        if case let .bool(value) = self { return value }
        if case let .number(value) = self { return value != 0 }
        return nil
    }

    func date() -> Date? {
        guard let value = string() else { return nil }
        return ProviderDateCodec.parse(value)
    }

    func integer() -> Int? {
        switch self {
        case let .number(value): return Int(value)
        case let .string(value): return Int(value)
        default: return nil
        }
    }
}
