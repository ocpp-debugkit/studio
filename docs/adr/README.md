# Architecture Decision Records

This directory records the significant architecture decisions for OCPP DebugKit
Studio. Each ADR captures one decision in a consistent form —
**Status → Context → Decision → Consequences** — so the reasoning behind the
project's shape stays legible over time.

ADRs are immutable once accepted: to change a decision, add a new ADR that
supersedes the old one rather than editing history.

| ADR | Title | Status |
| --- | --- | --- |
| [0001](0001-independent-implementation.md) | Independent implementation with a shared conformance contract | Accepted |
| [0002](0002-macos-first-platforms.md) | macOS-first, Linux in CI, Windows post-1.0 | Accepted |
| [0003](0003-native-rendered-ui.md) | Native-rendered UI, no WebView | Accepted |
| [0004](0004-zig-native-sdk-zero-config.md) | Zig + Native SDK on the zero-config build | Accepted |
| [0005](0005-engine-value-representation.md) | Engine value representation & version-tagged decoder boundary | Accepted |
| [0006](0006-inspector-builder-view.md) | Inspector as a Zig builder view (not `.native` markup) | Accepted |
| [0007](0007-trusted-ingestion.md) | Trusted-ingestion limits for user-opened traces | Accepted |
| [0008](0008-websocket-transport.md) | WebSocket transport: a hand-rolled RFC 6455 subset | Accepted |
| [0009](0009-live-capture-effects-channel.md) | Live-capture effects channel (`update_fx` + `fx.spawn`) | Accepted |
| [0010](0010-live-proxy-transport-concurrency.md) | Live-proxy transport & concurrency | Accepted |
