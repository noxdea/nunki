# ADR 002: Implement the stable MCP transports directly

- Status: Accepted
- Date: 2026-09-15

## Context

Nunki needs only the MCP client lifecycle plus tools, resources, and prompts.
Adding a full protocol framework would expand dependencies and expose unrelated
host features.

## Decision

Implement MCP 2025-11-25 JSON-RPC over its stable newline-delimited stdio and
Streamable HTTP transports. Validate and bound every message. Serialize client
requests, enforce timeouts, negotiate the exact supported version, and cleanly
terminate stdio children and HTTP sessions.

## Consequences

The core has no runtime dependencies. Legacy HTTP+SSE, server-side features,
sampling, elicitation, tasks, and subscriptions remain outside 0.1.0 and can be
added only when a host needs them.
