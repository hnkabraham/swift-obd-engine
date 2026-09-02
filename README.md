# OBDEngine

A Swift package for talking to vehicles over ELM327-compatible OBD-II adapters: connection
management, SAE J1979 (Mode 01/02/03/06/07/09/0A) parsing, ISO 14229 (UDS) enhanced diagnostics,
and a built-in demo/simulator mode for developing without hardware.

## Why this one

Most Swift OBD-II libraries stop at "send an AT command, parse one line of hex." This one was
built for real, messy vehicles:

- **Multi-ECU arbitration** — a query can get responses from several control modules; the
  transport tracks which physical frames belong to which ECU rather than concatenating them.
- **ISO-TP reassembly** — multi-frame (`CAF1`) CAN responses are reassembled in sequence, with
  out-of-order and bad-sequence continuations rejected rather than silently corrupting data.
- **Legacy protocol support** — J1850, ISO 9141-2, and ISO 14230 (KWP) headers and checksums are
  validated and stripped before PID parsing, not just ISO 15765 (CAN).
- **UDS enhanced diagnostics** — service `0x22` (read data by identifier) and `0x19` (read DTC
  information) on top of the standard Mode 06 monitor results.
- **Adapter-aware transport policy** — bounded reconnect/backoff, a `STOPPED`-response retry
  policy, and per-vehicle protocol/PID-support caching so reconnecting to the same car doesn't
  re-probe everything from scratch.
- **A real demo mode** — every read method has a simulator fallback, so you can build and test an
  app's UI without a car or an adapter plugged in.

This came out of building a couple of iOS diagnostic apps and needing the protocol layer to be
solid enough to trust; it's a standalone extraction of that layer, not a toy.

## What's in the box

Two targets:

- **`OBDModels`** — the data types: `Vehicle`, `DiagnosticTroubleCode`, `PIDDefinition`/`PIDValue`,
  `FreezeFrameData`, `ReadinessMonitor`, `OBDScanResult`, custom-PID definitions, and the standard
  SAE PID/DTC tables.
- **`OBDEngine`** — the transport and protocol logic: `ELM327Command`, the BLE central and adapter
  profile resolution, `OBDConnectionManager`, `OBDParser`, and `OBDService` (the main entry point).

No UI, no cloud calls, no telemetry, no AI diagnosis layer — just the vehicle communication.

## Requirements

- Swift 5.9+, iOS 16+ / macOS 13+
- CoreBluetooth (for BLE ELM327 adapters — MFi/classic Bluetooth accessories are handled through
  `ExternalAccessory` in your app, not this package)
- If your app targets an MFi accessory (e.g. an OBDLink MFi adapter), declare its protocol string
  (e.g. `com.obdlink`) and `bluetooth-central`/`external-accessory` background modes in your own
  app's `Info.plist` — this package doesn't ship an app bundle, so that declaration has to live in
  the app that links it.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/holystreetballer/swift-obd-engine.git", from: "1.0.0")
]
```

## Usage

```swift
import OBDEngine
import OBDModels

let service = OBDService() // wraps a real CoreBluetooth central by default
let vehicle = Vehicle(make: "Honda", model: "Civic", year: 2019)

service.onVehicleLinkStateChange = { state in
    // .adapterConnected -> .initializingAdapter -> .searchingVehicleProtocol -> .vehicleReady
}

service.connect() // starts scanning for a paired ELM327/OBDLink-style adapter
try await service.initialize(for: vehicle) // runs SAE Mode 01 protocol discovery once connected

let dtcs = try await service.readStoredDTCs()
let rpm = try await service.readPID(StandardPIDLibrary.engineRPM)

// Or read everything in one call:
let scan = try await service.performFullScan(vehicle: vehicle)
print(scan.dtcs, scan.readinessMonitors, scan.liveData)
```

No adapter on hand? Call `service.connectDemo(vehicle: vehicle)` instead of `connect()` and every
read method above returns plausible simulated data rather than talking to real hardware.

## Testing

```bash
swift test
```

208 tests covering protocol parsing correctness, transport reassembly/backpressure, reconnect and
retry policy, and adapter selection — all against scripted transports, no hardware required.

## License

MIT — see [LICENSE](LICENSE).
