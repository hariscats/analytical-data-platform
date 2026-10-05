# 20-minute workshop

## Goal

Publish synthetic hyperspectral imagery as a selective, bounded, read-only API. Then
show that every layer between the caller and the data makes its own authorization
decision: Microsoft Entra ID, API Management, Data API builder, and PostgreSQL.

## Before the session

Run `bash scripts/up.sh` or `pwsh ./scripts/up.ps1` 15 minutes ahead; APIM Basic v2
takes a few minutes to provision. Keep [`dab/dab-config.json`](../dab/dab-config.json) and
[`infra/policies/api.xml.tftpl`](../infra/policies/api.xml.tftpl) open.

## Flow

Run `bash scripts/demo.sh` or `pwsh ./scripts/demo.ps1`, then pause after each group of steps.

| Time | Demo steps | Demonstration | Decision to capture |
|---|---|---|---|
| 0–3 min | — | Walk the architecture and the two grains: one row per scene; one reflectance sample per scene × pixel × band | What grain does each consumer actually need? |
| 3–7 min | 2, 6 | `$select`, `$filter`, explicit `$orderby`, `$first=200`; follow `nextLink` and show that page 2 continues exactly where page 1 stopped | Field list, filter set, sort order, page cap. Is live continuation enough, or is a versioned extract required? |
| 7–10 min | 7 | APIM rejects unsupported shapes: no scene filter, `or`, `$first=5000`, unknown parameters | Which query shapes are part of the contract, and which layer enforces them? |
| 10–14 min | 3, 4, 5, 8 | Same API, different roles: mission row policy, hidden coordinates, spectra denied to the catalog role | Where are field and row entitlements managed and reviewed? |
| 14–17 min | 1, 9, 10 | No token, role spoofing, calling DAB directly, writes | Which controls must hold even if the gateway is bypassed? |
| 17–20 min | 3, 11 | PostgreSQL row-level security and column grants hold whatever DAB says; the DAB login has no password | Which rules belong in the database, and which in the API configuration? |

## Acceptance checks

- Responses contain only declared fields, and internal columns are unreachable even
  through direct SQL as the API's role.
- Every collection read has a page cap and returns a `nextLink` when more rows exist.
  Spectra reads are limited to one scene.
- Mission A and Mission B analysts can't see each other's rows. The catalog role sees
  both missions but no coordinates or spectra.
- Embargoed scenes never leave PostgreSQL, for any role.
- Missing tokens, spoofed roles, unsupported query shapes, and writes are all rejected,
  and the demo names the layer that rejected each one.
- Onboarding another dataset changes a view, grants, and DAB configuration, not
  application code.

## Discussion: DAB or a custom API?

| Question | This template | Custom API |
|---|---|---|
| Standard projection, filter, and paging | Configuration | How much code to maintain? |
| Stable continuation | Built in (keyset `$after`) | What cursor contract and tests exist? |
| Field and row authorization | DAB permissions plus PostgreSQL grants and row-level security | Where is it enforced and tested? |
| Per-caller identity inside the database | Not available for PostgreSQL (SQL Server only) | Possible, at the cost of per-user connections |
| Array or file responses, such as whole spectra or band images | Out of scope | Justified custom endpoint or export job |

Choose the smallest implementation that meets the agreed contract, authorization,
workload, and operating model.
