import Foundation
import Libmpv

/// A property value delivered by libmpv, decoded from the format it was observed with.
enum MPVValue: Sendable, Equatable {
    case none
    case flag(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    indirect case array([MPVValue])
    indirect case map([String: MPVValue])

    var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    var flagValue: Bool? {
        if case .flag(let value) = self { value } else { nil }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var intValue: Int? {
        if case .int(let value) = self { Int(value) } else { nil }
    }

    var arrayValue: [MPVValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    subscript(key: String) -> MPVValue? {
        if case .map(let value) = self { value[key] } else { nil }
    }
}

/// Property formats `MPVPlayer.observe` supports.
enum MPVFormat: Sendable {
    case flag
    case int
    case double
    case string
    /// Structured values (lists, maps), decoded into `MPVValue.array` / `.map`.
    case node

    var raw: mpv_format {
        switch self {
        case .flag: MPV_FORMAT_FLAG
        case .int: MPV_FORMAT_INT64
        case .double: MPV_FORMAT_DOUBLE
        case .string: MPV_FORMAT_STRING
        case .node: MPV_FORMAT_NODE
        }
    }
}

/// Why playback of a file ended.
enum MPVEndReason: Sendable {
    /// The file played to its end.
    case endOfFile
    case error
    /// Stopped by a command, by quitting, or replaced by another file.
    case stopped
}

/// The subset of libmpv events the app consumes.
enum MPVEvent: Sendable {
    case propertyChanged(name: String, value: MPVValue)
    case fileLoaded
    case endFile(MPVEndReason)
    case playbackRestart
    case videoReconfig
    /// A `script-message` broadcast, e.g. from an input.conf binding.
    case clientMessage([String])
    case log(prefix: String, level: String, text: String)
    case shutdown

    /// Decodes a raw event. Returns nil for events the app ignores.
    init?(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else {
                return nil
            }
            self = .propertyChanged(name: String(cString: property.name), value: MPVValue(property))
        case MPV_EVENT_FILE_LOADED:
            self = .fileLoaded
        case MPV_EVENT_END_FILE:
            let reason = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
            self = .endFile(reason == MPV_END_FILE_REASON_EOF ? .endOfFile : reason == MPV_END_FILE_REASON_ERROR ? .error : .stopped)
        case MPV_EVENT_PLAYBACK_RESTART:
            self = .playbackRestart
        case MPV_EVENT_VIDEO_RECONFIG:
            self = .videoReconfig
        case MPV_EVENT_LOG_MESSAGE:
            guard let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee else {
                return nil
            }
            self = .log(
                prefix: String(cString: message.prefix),
                level: String(cString: message.level),
                text: String(cString: message.text)
            )
        case MPV_EVENT_CLIENT_MESSAGE:
            guard let message = event.data?.assumingMemoryBound(to: mpv_event_client_message.self).pointee else {
                return nil
            }
            self = .clientMessage((0..<Int(message.num_args)).map { String(cString: message.args[$0]!) })
        case MPV_EVENT_SHUTDOWN:
            self = .shutdown
        default:
            return nil
        }
    }
}

private extension MPVValue {
    init(_ property: mpv_event_property) {
        guard let data = property.data else {
            self = .none
            return
        }
        switch property.format {
        case MPV_FORMAT_FLAG:
            self = .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_INT64:
            self = .int(data.assumingMemoryBound(to: Int64.self).pointee)
        case MPV_FORMAT_DOUBLE:
            self = .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_STRING:
            // MPV_FORMAT_STRING data is a `char **`.
            if let cString = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                self = .string(String(cString: cString))
            } else {
                self = .none
            }
        case MPV_FORMAT_NODE:
            self = MPVValue(data.assumingMemoryBound(to: mpv_node.self).pointee)
        default:
            self = .none
        }
    }

    init(_ node: mpv_node) {
        switch node.format {
        case MPV_FORMAT_FLAG:
            self = .flag(node.u.flag != 0)
        case MPV_FORMAT_INT64:
            self = .int(node.u.int64)
        case MPV_FORMAT_DOUBLE:
            self = .double(node.u.double_)
        case MPV_FORMAT_STRING:
            self = .string(String(cString: node.u.string))
        case MPV_FORMAT_NODE_ARRAY:
            let list = node.u.list.pointee
            self = .array((0..<Int(list.num)).map { MPVValue(list.values[$0]) })
        case MPV_FORMAT_NODE_MAP:
            let list = node.u.list.pointee
            var map: [String: MPVValue] = [:]
            for index in 0..<Int(list.num) {
                map[String(cString: list.keys[index]!)] = MPVValue(list.values[index])
            }
            self = .map(map)
        default:
            self = .none
        }
    }
}
