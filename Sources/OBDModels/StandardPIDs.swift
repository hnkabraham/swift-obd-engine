import Foundation

public enum StandardPIDLibrary {
    public static let allPIDs: [PIDDefinition] = [
        engineRPM, vehicleSpeed, coolantTemp, intakeAirTemp,
        mafRate, mapPressure, throttlePosition, calculatedLoad,
        timingAdvance, fuelSystemStatus, fuelLevel, fuelPressure,
        fuelTrimShortTerm1, fuelTrimLongTerm1, fuelTrimShortTerm2, fuelTrimLongTerm2,
        o2Sensor1_1, o2Sensor1_2, o2Sensor2_1, o2Sensor2_2,
        controlModuleVoltage, ambientAirTemp, barometricPressure,
        egrCommanded, evapPurge, catalystTemp1, catalystTemp2,
        absLoad, fuelRailPressure, runTimeSinceStart, distanceWithMIL,
        warmupsSinceCleared, commandedEquivRatio, o2Bank1Sensor1Wide,
        o2Bank2Sensor1Wide, engineOilTemp,
    ]

    public static func definition(for hexCode: String) -> PIDDefinition? {
        let normalized = hexCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "0X", with: "")
        return allPIDs.first { $0.hexCode == normalized }
    }

    // MARK: - Standard SAE J1979 PIDs (Mode 01)

    public static let engineRPM = PIDDefinition(
        hexCode: "0C", name: "Engine RPM", description: "Engine revolutions per minute",
        unit: "rpm", minValue: 0, maxValue: 16384,
        category: .engine, equation: .linear(multiplier: 0.25, offset: 0))

    public static let vehicleSpeed = PIDDefinition(
        hexCode: "0D", name: "Vehicle Speed", description: "Vehicle speed from ECU",
        unit: "km/h", minValue: 0, maxValue: 255,
        category: .speed, equation: .linear(multiplier: 1, offset: 0))

    public static let coolantTemp = PIDDefinition(
        hexCode: "05", name: "Coolant Temperature", description: "Engine coolant temperature",
        unit: "°C", minValue: -40, maxValue: 215,
        category: .temperature, equation: .linear(multiplier: 1, offset: -40))

    public static let intakeAirTemp = PIDDefinition(
        hexCode: "0F", name: "Intake Air Temperature", description: "Intake air temperature",
        unit: "°C", minValue: -40, maxValue: 215,
        category: .temperature, equation: .linear(multiplier: 1, offset: -40))

    public static let mafRate = PIDDefinition(
        hexCode: "10", name: "MAF Rate", description: "Mass air flow rate",
        unit: "g/s", minValue: 0, maxValue: 655,
        category: .fuel, equation: .linear(multiplier: 0.01, offset: 0))

    public static let mapPressure = PIDDefinition(
        hexCode: "0B", name: "MAP Pressure", description: "Manifold absolute pressure",
        unit: "kPa", minValue: 0, maxValue: 255,
        category: .pressure, equation: .linear(multiplier: 1, offset: 0))

    public static let throttlePosition = PIDDefinition(
        hexCode: "11", name: "Throttle Position", description: "Absolute throttle position",
        unit: "%", minValue: 0, maxValue: 100,
        category: .engine, equation: .linear(multiplier: 0.392, offset: 0))

    public static let calculatedLoad = PIDDefinition(
        hexCode: "04", name: "Engine Load", description: "Calculated engine load value",
        unit: "%", minValue: 0, maxValue: 100,
        category: .engine, equation: .linear(multiplier: 0.392, offset: 0))

    public static let timingAdvance = PIDDefinition(
        hexCode: "0E", name: "Timing Advance", description: "Ignition timing advance for #1 cylinder",
        unit: "°", minValue: -64, maxValue: 64,
        category: .engine, equation: .linear(multiplier: 0.5, offset: -64))

    public static let fuelSystemStatus = PIDDefinition(
        hexCode: "03", name: "Fuel System Status", description: "Fuel system loop status",
        unit: "", minValue: 0, maxValue: 255,
        category: .fuel, equation: .bitEncoded(mask: 0xFF, shift: 0))

    public static let fuelLevel = PIDDefinition(
        hexCode: "2F", name: "Fuel Level", description: "Fuel tank level input",
        unit: "%", minValue: 0, maxValue: 100,
        category: .fuel, equation: .linear(multiplier: 0.392, offset: 0))

    public static let fuelPressure = PIDDefinition(
        hexCode: "0A", name: "Fuel Rail Pressure", description: "Fuel rail pressure (gauge)",
        unit: "kPa", minValue: 0, maxValue: 765,
        category: .fuel, equation: .linear(multiplier: 3, offset: 0))

    public static let fuelTrimShortTerm1 = PIDDefinition(
        hexCode: "06", name: "Short Term Fuel Trim Bank 1", description: "Short term fuel trim - Bank 1",
        unit: "%", minValue: -100, maxValue: 100,
        category: .fuel, equation: .linear(multiplier: 0.781, offset: -100))

    public static let fuelTrimLongTerm1 = PIDDefinition(
        hexCode: "07", name: "Long Term Fuel Trim Bank 1", description: "Long term fuel trim - Bank 1",
        unit: "%", minValue: -100, maxValue: 100,
        category: .fuel, equation: .linear(multiplier: 0.781, offset: -100))

    public static let fuelTrimShortTerm2 = PIDDefinition(
        hexCode: "08", name: "Short Term Fuel Trim Bank 2", description: "Short term fuel trim - Bank 2",
        unit: "%", minValue: -100, maxValue: 100,
        category: .fuel, equation: .linear(multiplier: 0.781, offset: -100))

    public static let fuelTrimLongTerm2 = PIDDefinition(
        hexCode: "09", name: "Long Term Fuel Trim Bank 2", description: "Long term fuel trim - Bank 2",
        unit: "%", minValue: -100, maxValue: 100,
        category: .fuel, equation: .linear(multiplier: 0.781, offset: -100))

    public static let o2Sensor1_1 = PIDDefinition(
        hexCode: "14", name: "O2 Sensor B1 S1 Voltage", description: "Oxygen sensor bank 1 sensor 1 voltage",
        unit: "V", minValue: 0, maxValue: 1.275,
        category: .emissions, equation: .linear(multiplier: 0.005, offset: 0))

    public static let o2Sensor1_2 = PIDDefinition(
        hexCode: "15", name: "O2 Sensor B1 S2 Voltage", description: "Oxygen sensor bank 1 sensor 2 voltage",
        unit: "V", minValue: 0, maxValue: 1.275,
        category: .emissions, equation: .linear(multiplier: 0.005, offset: 0))

    public static let o2Sensor2_1 = PIDDefinition(
        hexCode: "18", name: "O2 Sensor B2 S1 Voltage", description: "Oxygen sensor bank 2 sensor 1 voltage",
        unit: "V", minValue: 0, maxValue: 1.275,
        category: .emissions, equation: .linear(multiplier: 0.005, offset: 0))

    public static let o2Sensor2_2 = PIDDefinition(
        hexCode: "19", name: "O2 Sensor B2 S2 Voltage", description: "Oxygen sensor bank 2 sensor 2 voltage",
        unit: "V", minValue: 0, maxValue: 1.275,
        category: .emissions, equation: .linear(multiplier: 0.005, offset: 0))

    public static let controlModuleVoltage = PIDDefinition(
        hexCode: "42", name: "Control Module Voltage", description: "Power input to the ECU",
        unit: "V", minValue: 0, maxValue: 65,
        category: .electrical, equation: .linear(multiplier: 0.001, offset: 0))

    public static let ambientAirTemp = PIDDefinition(
        hexCode: "46", name: "Ambient Air Temperature", description: "Outside air temperature",
        unit: "°C", minValue: -40, maxValue: 215,
        category: .temperature, equation: .linear(multiplier: 1, offset: -40))

    public static let barometricPressure = PIDDefinition(
        hexCode: "33", name: "Barometric Pressure", description: "Atmospheric barometric pressure",
        unit: "kPa", minValue: 0, maxValue: 255,
        category: .pressure, equation: .linear(multiplier: 1, offset: 0))

    public static let egrCommanded = PIDDefinition(
        hexCode: "2C", name: "EGR Commanded", description: "Commanded EGR percentage",
        unit: "%", minValue: 0, maxValue: 100,
        category: .emissions, equation: .linear(multiplier: 0.392, offset: 0))

    public static let evapPurge = PIDDefinition(
        hexCode: "2E", name: "EVAP Purge", description: "Commanded evaporative purge",
        unit: "%", minValue: 0, maxValue: 100,
        category: .emissions, equation: .linear(multiplier: 0.392, offset: 0))

    public static let catalystTemp1 = PIDDefinition(
        hexCode: "3C", name: "Catalyst Temp B1 S1", description: "Catalyst temperature bank 1 sensor 1",
        unit: "°C", minValue: -40, maxValue: 6514,
        category: .emissions, equation: .linear(multiplier: 0.1, offset: -40))

    public static let catalystTemp2 = PIDDefinition(
        hexCode: "3E", name: "Catalyst Temp B2 S1", description: "Catalyst temperature bank 2 sensor 1",
        unit: "°C", minValue: -40, maxValue: 6514,
        category: .emissions, equation: .linear(multiplier: 0.1, offset: -40))

    public static let absLoad = PIDDefinition(
        hexCode: "43", name: "Absolute Load", description: "Absolute load value",
        unit: "%", minValue: 0, maxValue: 257,
        category: .engine, equation: .linear(multiplier: 0.392, offset: 0))

    public static let fuelRailPressure = PIDDefinition(
        hexCode: "23", name: "Fuel Rail Pressure (Direct)", description: "Fuel rail pressure (diesel/high-pressure)",
        unit: "kPa", minValue: 0, maxValue: 655350,
        category: .fuel, equation: .linear(multiplier: 10, offset: 0))

    public static let runTimeSinceStart = PIDDefinition(
        hexCode: "1F", name: "Runtime Since Start", description: "Engine run time since start",
        unit: "s", minValue: 0, maxValue: 65535,
        category: .engine, equation: .linear(multiplier: 1, offset: 0))

    public static let distanceWithMIL = PIDDefinition(
        hexCode: "21", name: "Distance with MIL On", description: "Distance traveled with malfunction indicator lamp on",
        unit: "km", minValue: 0, maxValue: 65535,
        category: .engine, equation: .linear(multiplier: 1, offset: 0))

    public static let warmupsSinceCleared = PIDDefinition(
        hexCode: "30", name: "Warm-ups Since Cleared", description: "Number of warm-up cycles since DTCs cleared",
        unit: "", minValue: 0, maxValue: 255,
        category: .emissions, equation: .linear(multiplier: 1, offset: 0))

    public static let commandedEquivRatio = PIDDefinition(
        hexCode: "44", name: "Commanded Equivalence Ratio", description: "Air-fuel equivalence ratio (lambda)",
        unit: "λ", minValue: 0, maxValue: 2,
        category: .fuel,
        // SAE J1979: λ = 2 × ((A×256)+B) / 65536, so 0x8000 is stoichiometric.
        equation: .linear(multiplier: 2.0 / 65536.0, offset: 0))

    public static let o2Bank1Sensor1Wide = PIDDefinition(
        hexCode: "24", name: "O2 Sensor 1 Wide-range",
        description: "Wide-range oxygen sensor 1 equivalence ratio",
        unit: "λ", minValue: 0, maxValue: 2,
        category: .emissions,
        // SAE J1979: λ = 2 × ((A×256)+B) / 65536, so 0x8000 is stoichiometric.
        equation: .custom(formula: "2 * ((A * 256) + B) / 65536"))

    public static let o2Bank2Sensor1Wide = PIDDefinition(
        hexCode: "25", name: "O2 Sensor 2 Wide-range",
        description: "Wide-range oxygen sensor 2 equivalence ratio",
        unit: "λ", minValue: 0, maxValue: 2,
        category: .emissions,
        // SAE J1979: λ = 2 × ((A×256)+B) / 65536, so 0x8000 is stoichiometric.
        equation: .custom(formula: "2 * ((A * 256) + B) / 65536"))

    public static let engineOilTemp = PIDDefinition(
        hexCode: "5C", name: "Engine Oil Temperature", description: "Engine oil temperature",
        unit: "°C", minValue: -40, maxValue: 210,
        category: .temperature, equation: .linear(multiplier: 1, offset: -40))
}
