# ADR 001: Keep network destinations explicit

- Status: Accepted
- Date: 2026-09-15

## Context

LLM vendors and local servers expose compatible APIs at different URLs. A
library-selected default would couple provider protocol support to product
policy and could silently send data to an unintended service.

## Decision

Require a complete HTTP(S) endpoint for every provider and MCP HTTP client.
Adapters add protocol headers and request shapes but never select a host. API
keys remain in memory and are not persisted. The host application owns endpoint
trust and authorization policy.

## Consequences

Nunki supports hosted and local services without product-specific settings.
Callers must treat endpoint configuration as an SSRF-capable input and validate
it before constructing a client.
