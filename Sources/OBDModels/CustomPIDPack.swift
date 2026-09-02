import Foundation

public enum CustomPIDValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case emptyField(String)
    case textTooLong(field: String, maximum: Int)
    case controlCharacters(String)
    case invalidHex(field: String)
    case unsupportedReadService(String)
    case invalidResponseByteCount(Int)
    case invalidRange
    case invalidPrecision(Int)
    case invalidFormula(String)
    case formulaTooComplex
    case missingResponseByte(Int)
    case divisionByZero
    case nonFiniteResult
    case resultOutOfRange
    case emptyPack
    case tooManyDefinitions(Int)
    case duplicateDefinitionID(UUID)
    case duplicateRequest(String)
    case duplicateName(String)
    case oversizedJSON

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Schema version \(version) is not supported."
        case .emptyField(let field):
            "\(field) cannot be empty."
        case .textTooLong(let field, let maximum):
            "\(field) must contain no more than \(maximum) characters."
        case .controlCharacters(let field):
            "\(field) contains unsupported control characters."
        case .invalidHex(let field):
            "\(field) must be an even-length hexadecimal value."
        case .unsupportedReadService(let service):
            "Custom dashboard PIDs support read-only Mode 01 only; service \(service) requires a physically addressed enhanced-module profile."
        case .invalidResponseByteCount(let count):
            "Response byte count \(count) is outside the supported range of 1 through 8."
        case .invalidRange:
            "The display range must contain finite values with a minimum below its maximum."
        case .invalidPrecision(let precision):
            "Display precision \(precision) is outside the supported range of 0 through 4."
        case .invalidFormula(let reason):
            "The scaling formula is invalid: \(reason)"
        case .formulaTooComplex:
            "The scaling formula exceeds the bounded complexity limit."
        case .missingResponseByte(let index):
            "The formula requires response byte \(Self.byteName(index)), which is unavailable."
        case .divisionByZero:
            "The scaling formula divided by zero."
        case .nonFiniteResult:
            "The scaling formula produced a non-finite or unbounded result."
        case .resultOutOfRange:
            "The scaled value is outside the configured display range."
        case .emptyPack:
            "A PID pack must contain at least one definition."
        case .tooManyDefinitions(let count):
            "A PID pack contains \(count) definitions; the maximum is 64."
        case .duplicateDefinitionID(let id):
            "The PID definition identifier \(id.uuidString) appears more than once."
        case .duplicateRequest(let request):
            "The read request \(request) appears more than once."
        case .duplicateName(let name):
            "The PID name “\(name)” appears more than once."
        case .oversizedJSON:
            "The PID pack JSON exceeds the 256 KB import limit."
        }
    }

    private static func byteName(_ index: Int) -> String {
        guard (0..<8).contains(index) else { return String(index + 1) }
        return String(UnicodeScalar(65 + index)!)
    }
}

enum CustomTelemetryValidation {
    static func text(
        _ value: String,
        field: String,
        maximumLength: Int,
        allowsEmpty: Bool = false
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowsEmpty, trimmed.isEmpty {
            throw CustomPIDValidationError.emptyField(field)
        }
        if trimmed.count > maximumLength {
            throw CustomPIDValidationError.textTooLong(
                field: field,
                maximum: maximumLength
            )
        }
        if trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) {
            throw CustomPIDValidationError.controlCharacters(field)
        }
        return trimmed
    }

    static func hexadecimal(
        _ value: String,
        field: String,
        minimumBytes: Int,
        maximumBytes: Int
    ) throws -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        if normalized.hasPrefix("0X") {
            normalized.removeFirst(2)
        }
        let allowedLengths = (minimumBytes...maximumBytes).map { $0 * 2 }
        guard allowedLengths.contains(normalized.count),
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789ABCDEF").contains($0)
              }) else {
            throw CustomPIDValidationError.invalidHex(field: field)
        }
        return normalized
    }
}

/// A read-only OBD request identifier. Write/clear/programming services are
/// deliberately impossible to represent.
public struct CustomPIDRequest: Codable, Hashable, Sendable {
    /// Custom dashboard formulas intentionally stay on functional Mode 01.
    /// Manufacturer services 0x21/0x22 require an explicit ECU address and
    /// belong in `EnhancedDiagnosticProfile`, where header restoration and
    /// response-source allowlisting are enforced.
    public static let allowedReadServices: Set<String> = ["01"]

    public let service: String
    public let parameter: String

    public var key: String { "\(service):\(parameter)" }
    public var commandHex: String { service + parameter }

    public init(service: String, parameter: String) throws {
        let normalizedService = try CustomTelemetryValidation.hexadecimal(
            service,
            field: "Service",
            minimumBytes: 1,
            maximumBytes: 1
        )
        guard Self.allowedReadServices.contains(normalizedService) else {
            throw CustomPIDValidationError.unsupportedReadService(
                normalizedService
            )
        }
        self.service = normalizedService
        self.parameter = try CustomTelemetryValidation.hexadecimal(
            parameter,
            field: "Parameter",
            minimumBytes: 1,
            maximumBytes: 1
        )
    }

    private enum CodingKeys: String, CodingKey {
        case service
        case parameter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            service: container.decode(String.self, forKey: .service),
            parameter: container.decode(String.self, forKey: .parameter)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(service, forKey: .service)
        try container.encode(parameter, forKey: .parameter)
    }
}

/// Supported display units use stable JSON identifiers. Arbitrary unit text is
/// intentionally not accepted because it can make a safe reading misleading.
public enum CustomPIDUnit: String, Codable, CaseIterable, Sendable {
    case unitless
    case rpm
    case kilometersPerHour = "km/h"
    case milesPerHour = "mph"
    case celsius = "degC"
    case fahrenheit = "degF"
    case percent
    case volts
    case millivolts
    case amperes
    case kilopascals = "kPa"
    case poundsPerSquareInch = "psi"
    case bar
    case gramsPerSecond = "g/s"
    case litersPerHour = "L/h"
    case seconds
    case milliseconds
    case degrees
    case newtonMeters = "N-m"

    public var symbol: String {
        switch self {
        case .unitless: ""
        case .rpm: "rpm"
        case .kilometersPerHour: "km/h"
        case .milesPerHour: "mph"
        case .celsius: "°C"
        case .fahrenheit: "°F"
        case .percent: "%"
        case .volts: "V"
        case .millivolts: "mV"
        case .amperes: "A"
        case .kilopascals: "kPa"
        case .poundsPerSquareInch: "psi"
        case .bar: "bar"
        case .gramsPerSecond: "g/s"
        case .litersPerHour: "L/h"
        case .seconds: "s"
        case .milliseconds: "ms"
        case .degrees: "°"
        case .newtonMeters: "N·m"
        }
    }
}

public struct CustomPIDValueRange: Codable, Hashable, Sendable {
    public let minimum: Double
    public let maximum: Double

    public init(minimum: Double, maximum: Double) throws {
        guard minimum.isFinite,
              maximum.isFinite,
              abs(minimum) <= 1_000_000_000_000,
              abs(maximum) <= 1_000_000_000_000,
              minimum < maximum else {
            throw CustomPIDValidationError.invalidRange
        }
        self.minimum = minimum
        self.maximum = maximum
    }

    /// Classifies a decoded value against the configured envelope. The bounds
    /// are inclusive, so a value exactly at the minimum or maximum is in range.
    public func status(for value: Double) -> CustomPIDRangeStatus {
        if value < minimum { return .belowMinimum }
        if value > maximum { return .aboveMaximum }
        return .withinRange
    }

    private enum CodingKeys: String, CodingKey {
        case minimum
        case maximum
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minimum: container.decode(Double.self, forKey: .minimum),
            maximum: container.decode(Double.self, forKey: .maximum)
        )
    }
}

/// Where a decoded reading sits relative to its configured display range.
///
/// An excursion is exactly the data a diagnostic app has to show — a
/// transmission running above its configured maximum is the reason the PID was
/// added — so the status travels with the value instead of discarding it.
public enum CustomPIDRangeStatus: String, Codable, Sendable {
    case belowMinimum
    case withinRange
    case aboveMaximum

    public var isOutOfRange: Bool { self != .withinRange }
}

/// A decoded custom-PID sample. A sample is missing only when the adapter
/// returned no usable data; a value outside the configured range is still a
/// real measurement and is reported with `rangeStatus` set accordingly.
public struct CustomPIDReading: Codable, Hashable, Sendable {
    public let value: Double
    public let rangeStatus: CustomPIDRangeStatus

    public var isOutOfRange: Bool { rangeStatus.isOutOfRange }

    public init(
        value: Double,
        rangeStatus: CustomPIDRangeStatus = .withinRange
    ) {
        self.value = value
        self.rangeStatus = rangeStatus
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case rangeStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            value: try container.decode(Double.self, forKey: .value),
            rangeStatus: try container.decodeIfPresent(
                CustomPIDRangeStatus.self,
                forKey: .rangeStatus
            ) ?? .withinRange
        )
    }
}

/// A small arithmetic expression over at most eight response bytes (`A`–`H`).
///
/// The expression is parsed by a bounded recursive-descent parser. It supports
/// numeric literals, parentheses, unary +/-, and +, -, *, /. It never invokes
/// JavaScript, `NSExpression`, a shell, reflection, or dynamically loaded code.
public struct BoundedPIDFormula: Codable, Hashable, Sendable {
    public let expression: String

    public var requiredResponseByteCount: Int {
        guard var parser = try? FormulaParser(expression: expression),
              let parsed = try? parser.parse() else {
            return 0
        }
        return parsed.references.max().map { $0 + 1 } ?? 0
    }

    public init(_ expression: String) throws {
        let normalized = expression.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else {
            throw CustomPIDValidationError.invalidFormula(
                "an expression is required"
            )
        }
        guard normalized.count <= FormulaParser.maximumCharacterCount else {
            throw CustomPIDValidationError.formulaTooComplex
        }
        var parser = try FormulaParser(expression: normalized)
        _ = try parser.parse()
        self.expression = normalized
    }

    public func evaluate(responseBytes: [UInt8]) throws -> Double {
        guard responseBytes.count <= 64 else {
            throw CustomPIDValidationError.formulaTooComplex
        }
        var parser = try FormulaParser(expression: expression)
        let parsed = try parser.parse()
        if let unavailable = parsed.references
            .filter({ $0 >= responseBytes.count })
            .min() {
            throw CustomPIDValidationError.missingResponseByte(unavailable)
        }
        var budget = 128
        return try parsed.node.evaluate(
            responseBytes: responseBytes,
            budget: &budget
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(expression)
    }
}

private struct ParsedFormula {
    let node: FormulaNode
    let references: Set<Int>
}

private indirect enum FormulaNode {
    case number(Double)
    case responseByte(Int)
    case unary(isNegative: Bool, FormulaNode)
    case binary(FormulaOperator, FormulaNode, FormulaNode)

    func evaluate(
        responseBytes: [UInt8],
        budget: inout Int
    ) throws -> Double {
        guard budget > 0 else {
            throw CustomPIDValidationError.formulaTooComplex
        }
        budget -= 1

        let result: Double
        switch self {
        case .number(let value):
            result = value
        case .responseByte(let index):
            guard responseBytes.indices.contains(index) else {
                throw CustomPIDValidationError.missingResponseByte(index)
            }
            result = Double(responseBytes[index])
        case .unary(let isNegative, let value):
            let evaluated = try value.evaluate(
                responseBytes: responseBytes,
                budget: &budget
            )
            result = isNegative ? -evaluated : evaluated
        case .binary(let operation, let left, let right):
            let lhs = try left.evaluate(
                responseBytes: responseBytes,
                budget: &budget
            )
            let rhs = try right.evaluate(
                responseBytes: responseBytes,
                budget: &budget
            )
            switch operation {
            case .add: result = lhs + rhs
            case .subtract: result = lhs - rhs
            case .multiply: result = lhs * rhs
            case .divide:
                guard rhs != 0 else {
                    throw CustomPIDValidationError.divisionByZero
                }
                result = lhs / rhs
            }
        }

        guard result.isFinite, abs(result) <= 1_000_000_000_000 else {
            throw CustomPIDValidationError.nonFiniteResult
        }
        return result
    }
}

private enum FormulaOperator {
    case add
    case subtract
    case multiply
    case divide
}

private enum FormulaToken: Equatable {
    case number(Double)
    case responseByte(Int)
    case plus
    case minus
    case multiply
    case divide
    case leftParenthesis
    case rightParenthesis
    case end
}

private struct FormulaParser {
    static let maximumCharacterCount = 256
    private static let maximumTokenCount = 128
    private static let maximumOperationCount = 64
    private static let maximumNestingDepth = 16

    private let tokens: [FormulaToken]
    private var position = 0
    private var operationCount = 0
    private var references = Set<Int>()

    init(expression: String) throws {
        tokens = try Self.tokenize(expression)
    }

    mutating func parse() throws -> ParsedFormula {
        let node = try parseExpression(depth: 0)
        guard current == .end else {
            throw CustomPIDValidationError.invalidFormula(
                "unexpected trailing input"
            )
        }
        return ParsedFormula(node: node, references: references)
    }

    private var current: FormulaToken {
        tokens[min(position, tokens.count - 1)]
    }

    private mutating func advance() {
        position = min(position + 1, tokens.count - 1)
    }

    private mutating func countOperation() throws {
        operationCount += 1
        guard operationCount <= Self.maximumOperationCount else {
            throw CustomPIDValidationError.formulaTooComplex
        }
    }

    private mutating func parseExpression(depth: Int) throws -> FormulaNode {
        var node = try parseTerm(depth: depth)
        while current == .plus || current == .minus {
            let operation: FormulaOperator = current == .plus
                ? .add
                : .subtract
            advance()
            try countOperation()
            node = .binary(
                operation,
                node,
                try parseTerm(depth: depth)
            )
        }
        return node
    }

    private mutating func parseTerm(depth: Int) throws -> FormulaNode {
        var node = try parseUnary(depth: depth)
        while current == .multiply || current == .divide {
            let operation: FormulaOperator = current == .multiply
                ? .multiply
                : .divide
            advance()
            try countOperation()
            node = .binary(
                operation,
                node,
                try parseUnary(depth: depth)
            )
        }
        return node
    }

    private mutating func parseUnary(depth: Int) throws -> FormulaNode {
        if current == .plus || current == .minus {
            let isNegative = current == .minus
            advance()
            try countOperation()
            return .unary(
                isNegative: isNegative,
                try parseUnary(depth: depth)
            )
        }
        return try parsePrimary(depth: depth)
    }

    private mutating func parsePrimary(depth: Int) throws -> FormulaNode {
        switch current {
        case .number(let value):
            advance()
            return .number(value)
        case .responseByte(let index):
            references.insert(index)
            advance()
            return .responseByte(index)
        case .leftParenthesis:
            guard depth < Self.maximumNestingDepth else {
                throw CustomPIDValidationError.formulaTooComplex
            }
            advance()
            let value = try parseExpression(depth: depth + 1)
            guard current == .rightParenthesis else {
                throw CustomPIDValidationError.invalidFormula(
                    "a closing parenthesis is missing"
                )
            }
            advance()
            return value
        default:
            throw CustomPIDValidationError.invalidFormula(
                "a number, response byte, or parenthesized expression was expected"
            )
        }
    }

    private static func tokenize(_ expression: String) throws -> [FormulaToken] {
        let bytes = Array(expression.utf8)
        var tokens: [FormulaToken] = []
        var index = 0

        func append(_ token: FormulaToken) throws {
            tokens.append(token)
            guard tokens.count <= maximumTokenCount else {
                throw CustomPIDValidationError.formulaTooComplex
            }
        }

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                index += 1
                continue
            }

            switch byte {
            case 43:
                try append(.plus)
                index += 1
            case 45:
                try append(.minus)
                index += 1
            case 42:
                try append(.multiply)
                index += 1
            case 47:
                try append(.divide)
                index += 1
            case 40:
                try append(.leftParenthesis)
                index += 1
            case 41:
                try append(.rightParenthesis)
                index += 1
            case 65...72, 97...104:
                let uppercase = byte >= 97 ? byte - 32 : byte
                try append(.responseByte(Int(uppercase - 65)))
                index += 1
            case 46, 48...57:
                let start = index
                var decimalPointCount = 0
                var digitCount = 0
                while index < bytes.count {
                    let candidate = bytes[index]
                    if candidate == 46 {
                        decimalPointCount += 1
                        index += 1
                    } else if (48...57).contains(candidate) {
                        digitCount += 1
                        index += 1
                    } else {
                        break
                    }
                }
                guard decimalPointCount <= 1,
                      digitCount > 0,
                      index - start <= 32,
                      let number = Double(
                          String(decoding: bytes[start..<index], as: UTF8.self)
                      ),
                      number.isFinite,
                      abs(number) <= 1_000_000_000_000 else {
                    throw CustomPIDValidationError.invalidFormula(
                        "a numeric literal is invalid"
                    )
                }
                try append(.number(number))
            default:
                throw CustomPIDValidationError.invalidFormula(
                    "only A–H, numbers, parentheses, and + - * / are allowed"
                )
            }
        }

        try append(.end)
        return tokens
    }
}

public enum CustomPIDCategory: String, Codable, CaseIterable, Sendable {
    case engine
    case fuel
    case emissions
    case transmission
    case speed
    case temperature
    case pressure
    case electrical
    case hybrid
    case custom
}

public struct CustomPIDDefinition: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let request: CustomPIDRequest
    public let name: String
    public let description: String
    public let responseByteCount: Int
    public let formula: BoundedPIDFormula
    public let unit: CustomPIDUnit
    public let valueRange: CustomPIDValueRange
    public let displayPrecision: Int
    public let category: CustomPIDCategory

    public init(
        id: UUID = UUID(),
        request: CustomPIDRequest,
        name: String,
        description: String = "",
        responseByteCount: Int,
        formula: BoundedPIDFormula,
        unit: CustomPIDUnit,
        valueRange: CustomPIDValueRange,
        displayPrecision: Int = 1,
        category: CustomPIDCategory = .custom
    ) throws {
        guard (1...8).contains(responseByteCount) else {
            throw CustomPIDValidationError.invalidResponseByteCount(
                responseByteCount
            )
        }
        guard formula.requiredResponseByteCount <= responseByteCount else {
            throw CustomPIDValidationError.missingResponseByte(
                formula.requiredResponseByteCount - 1
            )
        }
        guard (0...4).contains(displayPrecision) else {
            throw CustomPIDValidationError.invalidPrecision(displayPrecision)
        }

        self.id = id
        self.request = request
        self.name = try CustomTelemetryValidation.text(
            name,
            field: "PID name",
            maximumLength: 80
        )
        self.description = try CustomTelemetryValidation.text(
            description,
            field: "PID description",
            maximumLength: 240,
            allowsEmpty: true
        )
        self.responseByteCount = responseByteCount
        self.formula = formula
        self.unit = unit
        self.valueRange = valueRange
        self.displayPrecision = displayPrecision
        self.category = category
    }

    /// Decodes an adapter response into a reading.
    ///
    /// Decoding fails only when there is nothing to decode — a payload shorter
    /// than the definition requires, or a formula that cannot be evaluated.
    /// A value outside `valueRange` is a genuine measurement, so it is returned
    /// with its excursion flagged rather than dropped as an unsupported PID.
    public func reading(from responseBytes: [UInt8]) throws -> CustomPIDReading {
        guard responseBytes.count >= responseByteCount else {
            throw CustomPIDValidationError.missingResponseByte(
                responseBytes.count
            )
        }
        let value = try formula.evaluate(
            responseBytes: Array(responseBytes.prefix(responseByteCount))
        )
        return CustomPIDReading(
            value: value,
            rangeStatus: valueRange.status(for: value)
        )
    }

    public func scaledValue(from responseBytes: [UInt8]) throws -> Double {
        try reading(from: responseBytes).value
    }

    /// Strict decode for pack authoring and import validation, where a sample
    /// outside the configured range means the definition itself is wrong. Live
    /// telemetry must never use it: an excursion has to reach the display.
    public func validatedScaledValue(
        from responseBytes: [UInt8]
    ) throws -> Double {
        let decoded = try reading(from: responseBytes)
        guard !decoded.isOutOfRange else {
            throw CustomPIDValidationError.resultOutOfRange
        }
        return decoded.value
    }

    public func formattedValue(_ value: Double) -> String {
        let number = String(
            format: "%.\(displayPrecision)f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
        return unit.symbol.isEmpty ? number : "\(number) \(unit.symbol)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case request
        case name
        case description
        case responseByteCount
        case formula
        case unit
        case valueRange
        case displayPrecision
        case category
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            request: container.decode(CustomPIDRequest.self, forKey: .request),
            name: container.decode(String.self, forKey: .name),
            description: container.decodeIfPresent(
                String.self,
                forKey: .description
            ) ?? "",
            responseByteCount: container.decode(
                Int.self,
                forKey: .responseByteCount
            ),
            formula: container.decode(
                BoundedPIDFormula.self,
                forKey: .formula
            ),
            unit: container.decode(CustomPIDUnit.self, forKey: .unit),
            valueRange: container.decode(
                CustomPIDValueRange.self,
                forKey: .valueRange
            ),
            displayPrecision: container.decodeIfPresent(
                Int.self,
                forKey: .displayPrecision
            ) ?? 1,
            category: container.decodeIfPresent(
                CustomPIDCategory.self,
                forKey: .category
            ) ?? .custom
        )
    }
}

/// Pack provenance is intentionally limited to user-entered values or a public
/// specification. This package does not bundle proprietary OEM PID definitions.
public enum CustomPIDPackOrigin: String, Codable, Sendable {
    case userProvided
    case publicSpecification
}

public struct CustomPIDPack: Codable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumDefinitionCount = 64

    public let schemaVersion: Int
    public let id: UUID
    public let name: String
    public let summary: String
    public let origin: CustomPIDPackOrigin
    public let createdAt: Date
    public let definitions: [CustomPIDDefinition]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        origin: CustomPIDPackOrigin = .userProvided,
        createdAt: Date = Date(),
        definitions: [CustomPIDDefinition]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CustomPIDValidationError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        guard !definitions.isEmpty else {
            throw CustomPIDValidationError.emptyPack
        }
        guard definitions.count <= Self.maximumDefinitionCount else {
            throw CustomPIDValidationError.tooManyDefinitions(
                definitions.count
            )
        }

        var identifiers = Set<UUID>()
        var requestKeys = Set<String>()
        var names = Set<String>()
        for definition in definitions {
            guard identifiers.insert(definition.id).inserted else {
                throw CustomPIDValidationError.duplicateDefinitionID(
                    definition.id
                )
            }
            guard requestKeys.insert(definition.request.key).inserted else {
                throw CustomPIDValidationError.duplicateRequest(
                    definition.request.key
                )
            }
            let normalizedName = definition.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard names.insert(normalizedName).inserted else {
                throw CustomPIDValidationError.duplicateName(definition.name)
            }
        }

        self.schemaVersion = schemaVersion
        self.id = id
        self.name = try CustomTelemetryValidation.text(
            name,
            field: "Pack name",
            maximumLength: 80
        )
        self.summary = try CustomTelemetryValidation.text(
            summary,
            field: "Pack summary",
            maximumLength: 280,
            allowsEmpty: true
        )
        self.origin = origin
        self.createdAt = createdAt
        self.definitions = definitions
    }

    public func replacingDefinitions(
        _ definitions: [CustomPIDDefinition]
    ) throws -> CustomPIDPack {
        try CustomPIDPack(
            schemaVersion: schemaVersion,
            id: id,
            name: name,
            summary: summary,
            origin: origin,
            createdAt: createdAt,
            definitions: definitions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case summary
        case origin
        case createdAt
        case definitions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(
                Int.self,
                forKey: .schemaVersion
            ),
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            summary: container.decodeIfPresent(
                String.self,
                forKey: .summary
            ) ?? "",
            origin: container.decodeIfPresent(
                CustomPIDPackOrigin.self,
                forKey: .origin
            ) ?? .userProvided,
            createdAt: container.decodeIfPresent(
                Date.self,
                forKey: .createdAt
            ) ?? Date(timeIntervalSince1970: 0),
            definitions: container.decode(
                [CustomPIDDefinition].self,
                forKey: .definitions
            )
        )
    }
}

public enum CustomPIDPackJSON {
    public static let maximumByteCount = 256 * 1_024

    public static func encode(_ pack: CustomPIDPack) throws -> Data {
        // Rebuilding proves programmatically supplied values still satisfy the
        // same constraints applied to imported JSON.
        _ = try CustomPIDPack(
            schemaVersion: pack.schemaVersion,
            id: pack.id,
            name: pack.name,
            summary: pack.summary,
            origin: pack.origin,
            createdAt: pack.createdAt,
            definitions: pack.definitions
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pack)
        guard data.count <= maximumByteCount else {
            throw CustomPIDValidationError.oversizedJSON
        }
        return data
    }

    public static func decode(_ data: Data) throws -> CustomPIDPack {
        guard data.count <= maximumByteCount else {
            throw CustomPIDValidationError.oversizedJSON
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CustomPIDPack.self, from: data)
    }
}
