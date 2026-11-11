import Foundation
import Libmpv

/// A property value delivered by libmpv, decoded from the format it was observed with.
enum MPVValue: Sendable, Equatable {
    case none
    case flag(Bool)
    case int(Int64)
    case double(Double)
    case string(String)

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
}

/// Property formats `MPVPlayer.observe` supports.
enum MPVFormat: Sendable {
    case flag
    case int
    case double
    case string

    var raw: mpv_format {
        switch self {
        case .flag: MPV_FORMAT_FLAG
        case .int: MPV_FORMAT_INT64
        case .double: MPV_FORMAT_DOUBLE
        case .string: MPV_FORMAT_STRING
        }
    }
}

/// The subset of libmpv events the app consumes.
enum MPVEvent: Sendable {
    case propertyChanged(name: String, value: MPVValue)
    case fileLoaded
    case endFile
    case playbackRestart
    case videoReconfig
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
            self = .endFile
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
        default:
            self = .none
        }
    }
}
