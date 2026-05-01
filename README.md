# Protowire Swift

**PXF** (Proto eXpressive Format) is a human-friendly text serialization format backed by protobuf schemas.

This is a Swift implementation of the `protowire` project, providing idiomatic Swift APIs for encoding and decoding PXF, standard Protobuf binary, and SBE (Simple Binary Encoding).

```pxf
@type infra.v1.ServerConfig

hostname = "web-01.prod.example.com"
port     = 8443
enabled  = true
status   = STATUS_SERVING

# Well-known type literals
created_at = 2026-04-29T21:00:00Z
timeout    = 30s

# Nested messages use block syntax
tls {
  cert_file = "/etc/ssl/cert.pem"
  key_file  = "/etc/ssl/key.pem"
  verify    = true
}

# Repeated fields use list syntax
tags = ["production", "us-east", "frontend"]

# Maps use : for key-value pairs
labels = {
  env: "production"
  team: "platform"
  "hello world": "quoted keys supported"
}
```

## Features

- **PXF Codec**: Human-friendly text format with support for comments, multi-line strings, and Well-Known Types (Timestamps, Durations).
- **PB Codec**: Schema-free binary Protobuf marshaling for native Swift structs using `Codable`.
- **SBE Codec**: Ultra-low-latency binary encoding for fixed-offset workloads.
- **Buf.build Integration**: Standard Protobuf support with code generation via `buf`.
- **API Envelope**: Standardized API response wrapper with transport and application error separation.

## Installation

Add the following to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/trendvidia/protowire-swift.git", from: "1.0.0")
```

## Usage

### 1. Protobuf Binary Encoding (`PBEncoder` / `PBDecoder`)

Marshal any Swift struct to/from Protobuf binary using standard `Codable` and integer `CodingKeys`.

```swift
import Protowire

struct Config: Codable {
    var hostname: String
    var enabled: Bool
    var tags: [String]
    
    enum CodingKeys: Int, CodingKey {
        case hostname = 1
        case enabled = 2
        case tags = 3
    }
}

// Encode
let cfg = Config(hostname: "web-01", enabled: true, tags: ["prod"])
let data = try PBEncoder().encode(cfg)

// Decode
let decoded = try PBDecoder().decode(Config.self, from: data)
```

### 2. PXF Text Format (`PXFEncoder` / `PXFDecoder`)

Bridge the human-friendly PXF format to your Swift types.

```swift
import Protowire

let pxfString = """
hostname = "web-01"
enabled = true
tags = ["prod", "us-east"]
"""

// Decode
let decoder = PXFDecoder()
let cfg = try decoder.decode(Config.self, from: pxfString)

// Encode
let encoder = PXFEncoder()
let output = try encoder.encode(cfg)
```

### 3. Advanced PXF Features

#### Three-State Tracking (Set, Null, Absent)

When performing PATCH updates, it's often necessary to distinguish between a field being explicitly set to null versus being absent.

```swift
let input = """
hostname = "new-name"
tags = null
"""

let (cfg, result) = try PXFDecoder().unmarshalFull(Config.self, from: input)

result.isSet("hostname") // true
result.isNull("tags")     // true
result.isAbsent("enabled") // true
```

#### Heterogeneous Data with google.protobuf.Any

Use the `TypeResolver` to decode `Any` fields in PXF.

```swift
class MyResolver: PXF.TypeResolver {
    func resolve(typeURL: String) -> Decodable.Type? {
        if typeURL == "example.v1.User" { return User.self }
        return nil
    }
}

let pxf = """
content = @type example.v1.User {
    name = "Alice"
}
"""

let decoder = PXFDecoder()
decoder.typeResolver = MyResolver()
let msg = try decoder.decode(Message.self, from: pxf)
```

### 4. High-Performance SBE Reading

Use the `SBE.View` API for zero-allocation reading of binary data.

```swift
let view = try SBE.View(data: data, template: tmpl)
let id = view.int("id")
let isActive = view.bool("active")

// Nested groups
let items = view.group("items")
for i in 0..<items.countEntries {
    let item = items.entry(i)
    print(item.string("name"))
}
```

### 5. API Envelope

A uniform structure for API responses that separates transport errors from application logic.

```swift
import Protowire

let response = Envelope.ok(status: 200, data: someData)

if let appError = response.error {
    print("Application error code: \(appError.code)")
}
```

## Integration with buf.build

This project uses `buf` to manage Protobuf schemas. To regenerate Swift code from `.proto` files:

```bash
buf generate
```

Generated files are located in `Sources/Protowire/*.pb.swift`.

## Project Structure

- `Sources/Protowire/Protowire.swift`: Low-level wire format primitives.
- `Sources/Protowire/PB.swift`: `Codable`-based Protobuf binary codec.
- `Sources/Protowire/PXF_*.swift`: Lexer, parser, and codecs for the PXF format.
- `Sources/Protowire/SBE_*.swift`: SBE primitives and template-based codecs.
- `Sources/Protowire/Envelope.swift`: API Response Envelope implementation.
- `proto/`: Original Protobuf schemas.

## License

This project is licensed under the MIT License.
