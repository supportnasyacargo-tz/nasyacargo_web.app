# Nasya Cargo — internal operations web app

Private staff workspace for **Nasya Cargo**. It manages shipments, customers, payments, expenses, packing lists, staff roles and the shipment data exposed to the public tracking page.

The public marketing website remains a separate project at [www.nasyacargo.com](https://www.nasyacargo.com). When the shared Supabase project is connected, this app will write shipment data and the website will read only the customer-safe result returned by `track_shipment()`.

## Current status

- Nasya Cargo name, logo, black/white/yellow theme and contact details are applied locally.
- Tracking and packing-list references use the `NASYA` brand prefix.
- Existing cargo workflows and Supabase security architecture are preserved.
- A production Supabase project, staff accounts and hosting are **not configured by this branding pass**.

## Modules

- **Dashboard** — operational overview
- **Create Shipment / Shipment Detail** — shipment lifecycle and status timeline
- **Public Tracking** — internal preview of the website tracking result
- **Packing Lists** — dispatch grouping and item allocation
- **Customers** — customer records
- **Payments / Expenses** — financial records
- **Staff Roles** — authenticated user and role management
- **Settings** — company, shipping, exchange-rate and printing configuration

## Local development

```bash
pnpm install
pnpm dev
```

Quality checks:

```bash
pnpm typecheck
pnpm test
pnpm build
```

`pnpm-lock.yaml` is the dependency lock file and should remain the source of truth.

## Supabase connection

Copy `.env.example` to `.env.local`, then set the browser-safe values for the Nasya Cargo Supabase project:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

Never place a `service_role` key in this frontend app or commit it to the repository. The schema and Row Level Security migrations are in `supabase/migrations/`. Authenticated staff receive the application permissions defined there; public tracking uses the restricted `track_shipment()` RPC instead of direct table access.

Staff users must be created through an approved server-side/admin workflow. Password-reset redirects can use the Edge Function secret `APP_URL`; until hosting is finalized, its fallback is `https://app.nasyacargo.com`.

## Deployment

The source repository is [supportnasyacargo-tz/nasyacargo_web.app](https://github.com/supportnasyacargo-tz/nasyacargo_web.app). The app builds to the static `dist/` directory with `pnpm build` and includes `vercel.json` so it can be imported into Vercel as a Vite project. Add the two Supabase environment variables in Vercel before the production deployment.
