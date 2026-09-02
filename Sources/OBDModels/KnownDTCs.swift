import Foundation

public enum KnownDTCs {
    public static let database: [String: (description: String, severity: DiagnosticTroubleCode.CodeSeverity, category: String)] = [
        "P0300": ("Random/Multiple Cylinder Misfire Detected", .high, "Engine Misfire"),
        "P0301": ("Cylinder 1 Misfire Detected", .high, "Engine Misfire"),
        "P0302": ("Cylinder 2 Misfire Detected", .high, "Engine Misfire"),
        "P0303": ("Cylinder 3 Misfire Detected", .high, "Engine Misfire"),
        "P0304": ("Cylinder 4 Misfire Detected", .high, "Engine Misfire"),
        "P0171": ("System Too Lean (Bank 1)", .medium, "Fuel System"),
        "P0172": ("System Too Rich (Bank 1)", .medium, "Fuel System"),
        "P0174": ("System Too Lean (Bank 2)", .medium, "Fuel System"),
        "P0420": ("Catalyst System Efficiency Below Threshold (Bank 1)", .medium, "Emissions"),
        "P0430": ("Catalyst System Efficiency Below Threshold (Bank 2)", .medium, "Emissions"),
        "P0442": ("EVAP System Small Leak Detected", .low, "Emissions"),
        "P0455": ("EVAP System Large Leak Detected", .medium, "Emissions"),
        "P0401": ("EGR Flow Insufficient Detected", .medium, "Emissions"),
        "P0135": ("O2 Sensor Heater Circuit Malfunction (Bank 1, Sensor 1)", .medium, "Oxygen Sensor"),
        "P0141": ("O2 Sensor Heater Circuit Malfunction (Bank 1, Sensor 2)", .medium, "Oxygen Sensor"),
        "P0155": ("O2 Sensor Heater Circuit Malfunction (Bank 2, Sensor 1)", .medium, "Oxygen Sensor"),
        "P0305": ("Cylinder 5 Misfire Detected", .high, "Engine Misfire"),
        "P0306": ("Cylinder 6 Misfire Detected", .high, "Engine Misfire"),
        // The P0300 block runs to cylinder 12. Stopping at P0306 de-rated a
        // V8's cylinder-8 misfire below the identical fault on cylinder 6,
        // while `likelyCauses` and `costRange` still matched on "P030" — so
        // the app handed out misfire causes for a code it called unknown.
        "P0307": ("Cylinder 7 Misfire Detected", .high, "Engine Misfire"),
        "P0308": ("Cylinder 8 Misfire Detected", .high, "Engine Misfire"),
        "P0309": ("Cylinder 9 Misfire Detected", .high, "Engine Misfire"),
        "P0310": ("Cylinder 10 Misfire Detected", .high, "Engine Misfire"),
        "P0311": ("Cylinder 11 Misfire Detected", .high, "Engine Misfire"),
        "P0312": ("Cylinder 12 Misfire Detected", .high, "Engine Misfire"),
        "P0313": ("Misfire Detected with Low Fuel Level", .medium, "Engine Misfire"),
        "P0314": ("Single Cylinder Misfire (Cylinder Not Specified)", .high, "Engine Misfire"),
        "P0316": ("Misfire Detected on Startup (First 1000 Revolutions)", .medium, "Engine Misfire"),
        // Stop-driving classifications. These are the faults the README tells
        // drivers to pull over for; without at least one `.critical` entry the
        // entire "do not drive / arrange a tow" branch is unreachable code.
        "P0217": ("Engine Over Temperature Condition", .critical, "Cooling System"),
        "P0218": ("Transmission Over Temperature Condition", .high, "Transmission"),
        "P0524": ("Engine Oil Pressure Too Low", .critical, "Oil System"),
        "P0521": ("Engine Oil Pressure Sensor/Switch Range/Performance", .high, "Oil System"),
        "P0522": ("Engine Oil Pressure Sensor/Switch Low Voltage", .high, "Oil System"),
        "P0523": ("Engine Oil Pressure Sensor/Switch High Voltage", .high, "Oil System"),
        "P0113": ("Intake Air Temperature Circuit High Input", .medium, "Sensor Circuit"),
        "P0118": ("Engine Coolant Temperature Circuit High Input", .medium, "Sensor Circuit"),
        "P0128": ("Coolant Thermostat Temperature Below Regulating Temperature", .medium, "Cooling System"),
        "P0340": ("Camshaft Position Sensor Circuit Malfunction", .high, "Engine Timing"),
        "P0335": ("Crankshaft Position Sensor Circuit Malfunction", .high, "Engine Timing"),
        "P0500": ("Vehicle Speed Sensor Malfunction", .medium, "Speed Sensor"),
        "P0700": ("Transmission Control System Malfunction", .high, "Transmission"),
        "P0740": ("Torque Converter Clutch Circuit Malfunction", .high, "Transmission"),
        "P0562": ("System Voltage Low", .low, "Electrical"),
        "P0601": ("Internal Control Module Memory Check Sum Error", .high, "ECU Internal"),
        "P2101": ("Throttle Actuator Control Motor Circuit Range/Performance", .high, "Throttle"),
        "P2181": ("Cooling System Performance", .medium, "Cooling System"),
        "P219A": ("Air-Fuel Ratio Cylinder Imbalance (Bank 1)", .medium, "Fuel System"),
        "P0011": ("Camshaft Position 'A' Timing Over-Advanced (Bank 1)", .high, "VVT System"),
        "P0101": ("Mass Air Flow Circuit Range/Performance", .medium, "Air Intake"),
        "P0325": ("Knock Sensor 1 Circuit Malfunction", .medium, "Engine Sensor"),
        "P0480": ("Cooling Fan 1 Control Circuit Malfunction", .medium, "Cooling System"),
        "P0520": ("Engine Oil Pressure Sensor/Switch Circuit Malfunction", .high, "Oil System"),
        "P2539": ("Low Pressure Fuel System Sensor Circuit", .medium, "Fuel System"),
        "P0456": ("EVAP System Very Small Leak Detected", .low, "Emissions"),
        "P0014": ("Camshaft Position 'B' Timing Over-Advanced (Bank 1)", .high, "VVT System"),
        "P2002": ("Diesel Particulate Filter Efficiency Below Threshold", .medium, "DPF"),
        "P20EE": ("SCR NOx Catalyst Efficiency Below Threshold", .medium, "Emissions"),
        "P0A80": ("Hybrid Battery Pack Deterioration", .medium, "Hybrid/EV"),
        "U0100": ("Lost Communication With ECM/PCM", .high, "Network"),
        "U0121": ("Lost Communication With ABS Control Module", .high, "Network"),
        "U0140": ("Lost Communication With Body Control Module", .medium, "Network"),
        "B1213": ("Airbag Warning Light Circuit Malfunction", .high, "Safety/Restraint"),
        "C0040": ("Right Front Wheel Speed Sensor Circuit Malfunction", .high, "ABS/Brake"),
        "C0035": ("Left Front Wheel Speed Sensor Circuit Malfunction", .high, "ABS/Brake"),
    ]

    public static func lookup(_ code: String) -> (description: String, severity: DiagnosticTroubleCode.CodeSeverity, category: String)? {
        let normalized = code.uppercased().trimmingCharacters(in: .whitespaces)
        return database[normalized]
    }
}
