# Shared Supabase setup

One Supabase project backs both repos: the Cargo App (`nasya-cargo-webapp`) reads and writes everything through Supabase Auth + the tables below; the public website (`nasya-website`) only ever calls the read-only `track_shipment()` function.

## 0. The rule about Production

**Never run a migration on Production from a branch whose pull request is still open.**
Merge to `main` first, then apply. Applying early is how the database ended up
ahead of `main` in September 2026: the `20260911*` release was live in
Production while PR #5 was still a draft, and nothing recorded that it had been
applied, so neither the database nor the repository could tell you.

Two things now keep that visible:

- `migrations/20260912085000_migration_ledger.sql` creates
  `supabase_migrations.schema_migrations` — one row per applied migration,
  backfilled by probing for objects each migration creates rather than by
  assumption. **Every new migration must end by inserting its own row**, exactly
  as `20260912090000` does:

  ```sql
  insert into supabase_migrations.schema_migrations (version, name)
  values ('<filename timestamp>', '<rest of the filename>')
  on conflict (version) do nothing;
  ```

- `tests/drift-check.sql` is read-only and returns, for every migration in this
  folder, whether the database actually has it. Run it before and after any
  release: every row up to the last APPLIED should be APPLIED, with no MISSING
  in between. `tests/drift-check-ledger.sql` then compares that against the
  ledger — every row should say `ok`.

## 1. Apply the schema

In the Supabase dashboard → SQL Editor, apply migrations in filename order:

1. `migrations/0001_shipments_and_auth.sql`
2. `migrations/20260808172013_shipping_rates_fx_and_invoice_snapshots.sql`
3. `migrations/20260808173840_harden_shipment_item_policy.sql`
4. `migrations/20260809145324_item_qr_packing_allocations.sql`

For an existing database that already has all migrations through `20260819130000_partial_packing_dispatch.sql`, apply the payment/status/extra-charge release in this exact order:

1. `migrations/20260911090000_cargo_extra_charges.sql`
2. `migrations/20260911091000_atomic_payment_recording.sql`
3. `migrations/20260911092000_status_transition_confirmation.sql`

Then run the rollback-only `tests/phase6_payment_status_extra_charges_qa.sql` and follow `STATUS_PAYMENT_CHARGES_ROLLOUT.md` for concurrency and authenticated UI verification. Apply the migrations before deploying the matching app build.

For the invoice-repair / discount / expense-idempotency release, apply in this
exact order, then deploy the matching app build:

1. `migrations/20260912085000_migration_ledger.sql`
2. `migrations/20260912090000_invoice_repair_discount_and_expense_idempotency.sql`

Run `tests/drift-check.sql` before and after. The second migration also
backfills `shipments.amount_paid` from POSTED payments — `20260911091000`
installed the recalculation trigger but deliberately left historical rows
alone, so shipments paid before it still rendered as Unpaid.
`tests/phase7_invoice_repair_discount_expense_qa.sql` is the rollback-only QA
body for this release: it must be run on a scratch database, not Production,
because it creates fixtures.

The item-QR migration adds stable item identities, authenticated Packing List boxes, and transaction-safe allocation RPCs. Do not apply it to Production until the matching Cargo App build is approved for deployment. Its rollback-only QA body is `tests/item_qr_packing_rollback_qa.sql`.

This creates: `customers`, `shipments`, `packing_lists`, `payment_records`, `expenses`, `company_settings`, `staff_profiles`, Row Level Security policies (authenticated staff only on every table), and the `track_shipment(text)` function granted to `anon`.

## 2. Environment variables

**Cargo App** (`.env.local`, copied from `.env.example`):
```
VITE_SUPABASE_URL=https://<nasya-project-ref>.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=<publishable key>
```

**Website** (`.env.local` in the public website project):
```
NEXT_PUBLIC_SUPABASE_URL=https://<nasya-project-ref>.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=<publishable key>
```

Same publishable key in both — it's safe to reuse since RLS + the RPC boundary is what actually restricts access, not key secrecy. Never put the `service_role` key in either project.

## 3. Create staff logins

The apps can't provision Supabase Auth accounts themselves (that needs the `service_role` key). In the dashboard → Authentication → Users → Add user, create at minimum:

- Create the first approved Nasya Cargo staff email, then set its role to **Admin** through the controlled setup workflow.
- Create any other staff accounts using unique staff emails and temporary passwords that must be changed at first sign-in.

## 4. Verify

- Log into the Cargo App, create a test shipment, confirm it appears in Supabase → Table Editor → `shipments`.
- On the website's tracking page, look up that shipment's tracking number — it should return live data through `track_shipment()`.
- Confirm an anon/unauthenticated request can't read the tables directly (e.g. `curl` the REST endpoint with the publishable key against `/rest/v1/shipments` — should get an empty/forbidden result, not data).

