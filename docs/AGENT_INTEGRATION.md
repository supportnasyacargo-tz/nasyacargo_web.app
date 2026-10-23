# n8n customer care and finance integration

This change prepares access. It does not deploy a function, apply a production migration, generate live credentials, or activate n8n workflows.

## Connection flow

1. Review and apply `supabase/migrations/20261015090000_agent_connections_and_approvals.sql` after the existing migrations. Test staging first. This adds connection, proposal and activity tables, and the protected permission columns already read by the GitHub app's login code.
2. Deploy `agent-api` to the same Supabase project as the app. `supabase/config.toml` disables the gateway's JWT check for this function because the function verifies its own connection token. Do not apply that setting to the staff functions. See [Supabase function configuration](https://supabase.com/docs/guides/functions/function-configuration).
3. Deploy the reviewed app build. Log in as an active Admin, open **Agents & Approvals**, and create separate Customer care and Finance connections. The key appears once and expires after 30 days. Revocation takes effect on every subsequent request and blocks pending proposals from posting.
4. In n8n create a separate **Header Auth** credential for each agent: name `Authorization`, value `Bearer <connection key>`. Never give an agent a staff password, Supabase secret/service-role key or shared Admin login.
5. Import the matching example from `docs/n8n/`, select its Header Auth credential, and run **Connection check**. The workflows are inactive and start with a manual trigger. Add the HTTP Request node to your existing agent workflow only after this check passes.

Endpoint: `POST https://<nasya-project-ref>.supabase.co/functions/v1/agent-api`

All normal responses are `{ "data": ... }`. Errors use `code` and HTTP 400/401/403/404/409/429/502. Tokens are hashed before the database call and stored only as SHA-256 digests plus a display prefix. Connection owners must remain active, have completed required password changes and retain the action's permission. Each connection allows 60 valid requests/minute, shared across API instances. Anonymous malformed requests still need the hosting platform's normal abuse controls.

## Actions

| Action | Customer care | Finance | Input |
| --- | --- | --- | --- |
| `connection.check` | Yes | Yes | `{}` |
| `shipment.track` | Yes | Yes, if owner can view shipments | `{ "number": "<shipment reference>" }` |
| `invoice.get` | No | Yes | `{ "number": "<shipment reference>" }` |
| `invoice.pdf` | No | Yes | Same input; returns PDF bytes |
| `accounts.list` | No | Yes, if owner can view accounting | `{}` |
| `finance.propose` | No | Yes, subject to operation permission | See below |
| `proposal.get` | No | Own connection only | `{ "id": "<proposal UUID>" }` |

Customer care receives only the customer-safe tracking RPC response. It cannot list customers, read financial records, expose internal notes, change statuses or post money. Finance invoice reads return finalized, non-voided invoice snapshots and active customer-billable charges. The PDF is a server-generated snapshot export, not the existing browser PDF layout. It creates no invoice or accounting entry. Its plain font supports Latin text; check international customer names before using it as the only external invoice copy.

For `invoice.pdf`, configure n8n's HTTP Request node **Response Format: File**, output field `invoice`. Treat returned documents as customer data and limit n8n execution retention. n8n access does not authorize automatically sending a document to any recipient.

## Finance proposals

Every proposal needs a UUID `idempotencyKey` generated once per intended operation. Reuse it on retries; reuse with changed data returns 409. Amounts below are illustrative input syntax, not real transactions.

```json
{
  "action": "finance.propose",
  "idempotencyKey": "<UUID generated for this operation>",
  "input": {
    "action": "payment.record",
    "payload": {
      "shipmentId": "<shipmentId from invoice.get>",
      "amount": 10,
      "currency": "USD",
      "method": "Cash",
      "date": "2026-10-15",
      "note": "<payment evidence reference>"
    }
  }
}
```

Supported proposal payloads:

- `payment.record`: `shipmentId`, `amount`, `currency`, `method`, `date`; optional `note`.
- `expense.record`: `amount`, `currency`, `method`, `date`, `category`, `description`, `expenseAccountCode`; optional `shipmentId`, `payee`, `reference`, `note`.
- `invoice.amend`: `shipmentId`, `grossAmount`, `discount`, `reason`; `discountReason` is required for a positive discount.
- `income.record`: `amount`, `currency`, `date`, `description`, `incomeAccountCode`, `receivingAccountCode`, `exchangeRate`; optional `reference`.

Currency is USD, TZS or AED. Payment method is Cash, Bank Transfer, M-Pesa, Card or Other. Account codes come from `accounts.list`; the existing accounting RPC verifies each account's type and validity. Receiving accounts are Cash `1000` or Bank `1010`. Arbitrary journal SQL, refunds, posted-entry deletion, rates, staff administration and direct posting are not exposed.

The API returns a **PENDING** proposal; never tell a customer it is paid or posted at this point. In **Agents & Approvals**, staff verifies the original evidence and all displayed values, enters a review reason, and chooses **Approve & post** or **Reject**. Posting requires an active Admin or Manager and the relevant current permission. Proposals expire after seven days. A shipment changed since proposal creation blocks posting and requires a fresh proposal. Approval and the existing business RPC execute in one database transaction. Repeated approval cannot create a second posting. Invoice amendments retain the existing reversal/reissue accounting behavior. Poll `proposal.get` to learn the outcome; `REJECTED` must not be retried as a new proposal without staff instruction.

## Validation and activation

- App TypeScript, build and 60 domain tests pass locally.
- Four contract tests and three Deno HTTP/PDF tests pass locally.
- All repository migrations apply to isolated PostgreSQL 17 with auth/storage stubs; `supabase/tests/agent_approvals_qa.sql` verifies scopes, no posting before approval, all four existing accounting RPCs, replay protection, stale proposals, expiry, forced-password gate, revocation, rate limit, balanced journals and grants. Synthetic fixtures roll back. This is not full hosted Supabase/Auth/Storage validation.
- The Nasya Cargo branding pass preserves the existing PDF modules, numbering tests and atomic `record_expense` workflow.
- Before production activation: compare the hosted schema with these migrations, run a staging authenticated UI review, test an actual authorized shipment, check PDF names/layout and connect each n8n credential separately. No production financial test entries were created.

Before activation, run a fresh read-only tracking check against the final Nasya Cargo website and verify one authorized test shipment. No live shipment or production-domain verification is recorded by this local branding pass.

