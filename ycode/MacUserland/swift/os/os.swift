// os.swift - Ycode's `os` Swift overlay (specs/macos/swift-runtime.md §4):
// the unified-logging types Swift code uses (Logger, OSLog, OSLogType,
// os_log with an interpolated message, the privacy and format
// specifiers). Ycode's own code, written from Apple's public `os` and
// `Logger` documentation; it is not Apple's overlay.
//
// Ycode keeps no log store. Messages are formatted only when the
// environment variable YCODE_OS_LOG is set, and then written to standard
// error as "<subsystem>[<category>] <type>: <message>". Private values are
// shown, because there is no log reader to redact for.

@_exported import os  // the Clang module (<os/log.h>, <os/lock.h>, ...)
import Darwin

/// The type of a log message.
@frozen
public struct OSLogType: Equatable, RawRepresentable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public init(_ rawValue: UInt8) { self.rawValue = rawValue }

  public static let `default` = OSLogType(rawValue: 0x00)
  public static let info = OSLogType(rawValue: 0x01)
  public static let debug = OSLogType(rawValue: 0x02)
  public static let error = OSLogType(rawValue: 0x10)
  public static let fault = OSLogType(rawValue: 0x11)

  var name: String {
    switch rawValue {
    case 0x01: return "info"
    case 0x02: return "debug"
    case 0x10: return "error"
    case 0x11: return "fault"
    default: return "default"
    }
  }
}

/// A log handle: a subsystem and a category.
public final class OSLog: @unchecked Sendable {
  public let subsystem: String
  public let category: String
  let enabled: Bool

  public init(subsystem: String, category: String) {
    self.subsystem = subsystem
    self.category = category
    self.enabled = true
  }

  init(disabled: ()) {
    subsystem = ""
    category = ""
    enabled = false
  }

  public static let `default` = OSLog(subsystem: "", category: "")
  public static let disabled = OSLog(disabled: ())

  public func isEnabled(type: OSLogType) -> Bool { enabled && _logging }
}

let _logging: Bool = getenv("YCODE_OS_LOG") != nil

func _write(_ log: OSLog, _ type: OSLogType, _ text: @autoclosure () -> String) {
  guard log.enabled && _logging else { return }
  var line = log.subsystem.isEmpty ? "" : "\(log.subsystem)[\(log.category)] "
  line += "\(type.name): \(text())\n"
  fputs(line, stderr)
}

/// How an interpolated value appears in a stored log.
public struct OSLogPrivacy: Equatable, Sendable {
  let value: UInt8
  public static let auto = OSLogPrivacy(value: 0)
  public static let `public` = OSLogPrivacy(value: 1)
  public static let `private` = OSLogPrivacy(value: 2)
  public static let sensitive = OSLogPrivacy(value: 3)
  public static func `private`(mask: OSLogPrivacy.Mask) -> OSLogPrivacy { .private }
  public static func auto(mask: OSLogPrivacy.Mask) -> OSLogPrivacy { .auto }
  public struct Mask: Equatable, Sendable {
    public static let hash = Mask()
    public static let none = Mask()
  }
}

/// Formatting of interpolated integers.
public struct OSLogIntegerFormatting: Sendable {
  let radix: Int
  let uppercase: Bool
  public static let decimal = OSLogIntegerFormatting(radix: 10, uppercase: false)
  public static func decimal(explicitPositiveSign: Bool = false, minDigits: Int = 0) -> OSLogIntegerFormatting {
    .decimal
  }
  public static let hex = OSLogIntegerFormatting(radix: 16, uppercase: false)
  public static func hex(explicitPrefix: Bool = false, includePrefix: Bool = false, uppercase: Bool = false,
                         minDigits: Int = 0) -> OSLogIntegerFormatting {
    OSLogIntegerFormatting(radix: 16, uppercase: uppercase)
  }
  public static let octal = OSLogIntegerFormatting(radix: 8, uppercase: false)
}

/// Formatting of interpolated floating-point values.
public struct OSLogFloatFormatting: Sendable {
  public static let automatic = OSLogFloatFormatting()
  public static func fixed(precision: Int = 6, explicitPositiveSign: Bool = false) -> OSLogFloatFormatting {
    OSLogFloatFormatting()
  }
  public static let fixed = OSLogFloatFormatting()
  public static let exponential = OSLogFloatFormatting()
  public static let hybrid = OSLogFloatFormatting()
}

/// Alignment of interpolated values.
public struct OSLogStringAlignment: Sendable {
  public static let none = OSLogStringAlignment()
  public static func left(columns: Int) -> OSLogStringAlignment { OSLogStringAlignment() }
  public static func right(columns: Int) -> OSLogStringAlignment { OSLogStringAlignment() }
}

/// The interpolation of a log message: values are captured lazily and
/// formatted only when the message is written.
public struct OSLogInterpolation: StringInterpolationProtocol {
  var parts: [() -> String] = []

  public init(literalCapacity: Int, interpolationCount: Int) {
    parts.reserveCapacity(interpolationCount * 2 + 1)
  }

  public mutating func appendLiteral(_ literal: String) {
    parts.append { literal }
  }

  public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> String,
                                           align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
    parts.append(value)
  }

  public mutating func appendInterpolation<T: CustomStringConvertible>(
    _ value: @autoclosure @escaping () -> T, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto
  ) {
    parts.append { value().description }
  }

  public mutating func appendInterpolation<T: BinaryInteger>(
    _ value: @autoclosure @escaping () -> T, format: OSLogIntegerFormatting = .decimal,
    align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto
  ) {
    parts.append { String(value(), radix: format.radix, uppercase: format.uppercase) }
  }

  public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Double,
                                           format: OSLogFloatFormatting = .automatic,
                                           align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
    parts.append { value().description }
  }

  public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Float,
                                           format: OSLogFloatFormatting = .automatic,
                                           align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
    parts.append { value().description }
  }

  public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Bool,
                                           align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
    parts.append { value() ? "true" : "false" }
  }

  public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Any.Type,
                                           align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
    parts.append { String(describing: value()) }
  }

  public mutating func appendInterpolation<T>(_ value: @autoclosure @escaping () -> T?,
                                              align: OSLogStringAlignment = .none,
                                              privacy: OSLogPrivacy = .auto) {
    parts.append { value().map { String(describing: $0) } ?? "nil" }
  }

  public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> any Error,
                                           privacy: OSLogPrivacy = .auto) {
    parts.append { String(describing: value()) }
  }
}

/// A log message: a string literal with interpolations.
public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
  let interpolation: OSLogInterpolation

  public init(stringInterpolation: OSLogInterpolation) {
    interpolation = stringInterpolation
  }

  public init(stringLiteral value: String) {
    var i = OSLogInterpolation(literalCapacity: value.utf8.count, interpolationCount: 0)
    i.appendLiteral(value)
    interpolation = i
  }

  var text: String { interpolation.parts.map { $0() }.joined() }
}

/// The Swift logging interface.
public struct Logger: @unchecked Sendable {
  public let log: OSLog

  public init() { log = .default }
  public init(subsystem: String, category: String) { log = OSLog(subsystem: subsystem, category: category) }
  public init(_ log: OSLog) { self.log = log }

  public func log(_ message: OSLogMessage) { _write(log, .default, message.text) }
  public func log(level: OSLogType, _ message: OSLogMessage) { _write(log, level, message.text) }
  public func trace(_ message: OSLogMessage) { _write(log, .debug, message.text) }
  public func debug(_ message: OSLogMessage) { _write(log, .debug, message.text) }
  public func info(_ message: OSLogMessage) { _write(log, .info, message.text) }
  public func notice(_ message: OSLogMessage) { _write(log, .default, message.text) }
  public func warning(_ message: OSLogMessage) { _write(log, .error, message.text) }
  public func error(_ message: OSLogMessage) { _write(log, .error, message.text) }
  public func critical(_ message: OSLogMessage) { _write(log, .fault, message.text) }
  public func fault(_ message: OSLogMessage) { _write(log, .fault, message.text) }
}

/// `os_log` with an interpolated message.
public func os_log(_ type: OSLogType = .default, log: OSLog = .default, _ message: OSLogMessage) {
  _write(log, type, message.text)
}

/// `os_log` with a C format string and arguments.
public func os_log(_ message: StaticString, dso: UnsafeRawPointer? = #dsohandle, log: OSLog = .default,
                   type: OSLogType = .default, _ args: CVarArg...) {
  guard log.enabled && _logging else { return }
  let text = message.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
  _write(log, type, withVaList(args) { va -> String in
    var buffer = [CChar](repeating: 0, count: 1024)
    _ = vsnprintf(&buffer, buffer.count, text, va)
    return String(cString: buffer)
  })
}
