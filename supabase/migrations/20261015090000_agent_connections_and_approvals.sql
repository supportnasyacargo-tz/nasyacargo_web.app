-- Additive integration: agents can read allowlisted data and submit proposals.
-- Only an authenticated human can execute a proposal using the existing RPCs.
begin;

-- GitHub main already reads these fields at login. Add them for installations
-- that have not received the UI permission schema, preserving role defaults.
alter table public.staff_profiles
  add column if not exists permissions_mode text not null default 'ROLE_DEFAULT' check (permissions_mode in ('ROLE_DEFAULT','CUSTOM')),
  add column if not exists permissions text[] not null default '{}';
create function public.guard_agent_owner_permissions()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and not public.is_staff_admin()
    and (new.permissions_mode is distinct from old.permissions_mode or new.permissions is distinct from old.permissions)
  then raise exception 'Only an active Admin can change delegated permissions.'; end if;
  return new;
end $$;
create trigger guard_agent_owner_permissions before update on public.staff_profiles
  for each row execute function public.guard_agent_owner_permissions();

create table public.agent_connections (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.staff_profiles(id),
  name text not null check (length(name) between 1 and 80),
  kind text not null check (kind in ('customer_care','finance')),
  token_hash text not null unique,
  token_prefix text not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  window_start timestamptz not null default now(),
  window_count integer not null default 0
);
create table public.agent_proposals (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.agent_connections(id),
  idempotency_key uuid not null,
  action text not null check (action in ('payment.record','expense.record','invoice.amend','income.record')),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  shipment_id text references public.shipments(id),
  snapshot_hash text,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  decided_at timestamptz,
  decided_by uuid references public.staff_profiles(id),
  decision_reason text,
  result jsonb,
  unique(connection_id, idempotency_key)
);
create index agent_proposals_pending_idx on public.agent_proposals(status, created_at);
create table public.agent_activity (
  id bigint generated always as identity primary key,
  connection_id uuid not null references public.agent_connections(id),
  action text not null,
  outcome text not null,
  occurred_at timestamptz not null default now()
);
create index agent_activity_connection_idx on public.agent_activity(connection_id, occurred_at desc);

-- Match the current UI permission model, including installations with no custom
-- permission columns yet. Never trust role/permissions sent by an agent.
create function public.agent_has_permission(p_actor uuid, p_permission text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; r text;
begin
  select to_jsonb(s) into v from public.staff_profiles s
  where s.id=p_actor and s.active and not s.must_change_password;
  if v is null then return false; end if;
  r := v->>'role';
  if r='Admin' then return true; end if;
  if v->>'permissions_mode'='CUSTOM' then
    return coalesce((v->'permissions') ? p_permission, false);
  end if;
  if r='Manager' then return p_permission=any(array['shipments.view','invoices.view','invoices.edit','payments.create','expenses.create']); end if;
  if r in ('Staff','Operations Staff') then return p_permission=any(array['shipments.view','invoices.view','payments.create']); end if;
  if r='Accountant' then return p_permission=any(array['invoices.view','invoices.edit','payments.create','expenses.create','accounting.view','accounting.create']); end if;
  return false;
end $$;
create function public.agent_is_admin(p_actor uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.staff_profiles where id=p_actor and role='Admin' and active and not must_change_password)
$$;

alter table public.agent_connections enable row level security;
alter table public.agent_proposals enable row level security;
alter table public.agent_activity enable row level security;
revoke all on public.agent_connections, public.agent_proposals, public.agent_activity from public, anon, authenticated;
-- Hashes, rate counters and raw credentials are never readable by staff clients.
grant select(id,owner_id,name,kind,token_prefix,expires_at,revoked_at,created_at,last_used_at) on public.agent_connections to authenticated;
grant select on public.agent_proposals, public.agent_activity to authenticated;
create policy agent_admin_connections on public.agent_connections for select to authenticated
  using (public.agent_is_admin((select auth.uid())));
create policy agent_finance_review on public.agent_proposals for select to authenticated
  using (public.agent_has_permission((select auth.uid()),case action
    when 'payment.record' then 'payments.create' when 'expense.record' then 'expenses.create'
    when 'invoice.amend' then 'invoices.edit' when 'income.record' then 'accounting.create' end));
create policy agent_admin_activity on public.agent_activity for select to authenticated
  using (public.agent_is_admin((select auth.uid())));

create function public.create_agent_connection(p_name text, p_kind text, p_expires_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t text; c public.agent_connections;
begin
  if not public.agent_is_admin(auth.uid()) then raise exception 'Active Admin access required.'; end if;
  if p_expires_at is null or p_expires_at<=now() or p_expires_at>now()+interval '90 days' then raise exception 'Expiry must be within 90 days.'; end if;
  t := 'tca_' || replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  insert into public.agent_connections(owner_id,name,kind,token_hash,token_prefix,expires_at)
  values(auth.uid(),btrim(p_name),p_kind,encode(sha256(convert_to(t,'UTF8')),'hex'),left(t,12),p_expires_at)
  returning * into c;
  insert into public.agent_activity(connection_id,action,outcome) values(c.id,'connection.create','success');
  return jsonb_build_object('id',c.id,'secret',t,'expiresAt',c.expires_at);
end $$;
create function public.revoke_agent_connection(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.agent_is_admin(auth.uid()) then raise exception 'Active Admin access required.'; end if;
  update public.agent_connections set revoked_at=now() where id=p_id and revoked_at is null;
  if found then insert into public.agent_activity(connection_id,action,outcome) values(p_id,'connection.revoke','success'); end if;
end $$;

-- This is the only service-role entry point. No arbitrary table names, SQL,
-- filters or RPC names are accepted. Every request checks the current owner.
create function public.agent_api_request(p_token_hash text, p_action text, p_input jsonb default '{}'::jsonb, p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.agent_connections; s public.shipments; q public.agent_proposals;
  required text; out_data jsonb; input jsonb := coalesce(p_input,'{}'::jsonb); target text; snap text;
begin
  select * into c from public.agent_connections where token_hash=p_token_hash for update;
  if c.id is null or c.revoked_at is not null or c.expires_at<=now()
    or not exists(select 1 from public.staff_profiles where id=c.owner_id and active and not must_change_password)
  then return jsonb_build_object('code','unauthorized'); end if;
  if c.window_start<=now()-interval '1 minute' then c.window_count:=0; c.window_start:=now(); end if;
  update public.agent_connections set window_count=c.window_count+1,window_start=c.window_start,last_used_at=now() where id=c.id;
  if c.window_count>=60 then return jsonb_build_object('code','rate_limited'); end if;
  if jsonb_typeof(input)<>'object' or octet_length(input::text)>16384 then return jsonb_build_object('code','invalid_input'); end if;
  required := case p_action
    when 'shipment.track' then 'shipments.view'
    when 'invoice.get' then 'invoices.view' when 'invoice.pdf' then 'invoices.view'
    when 'accounts.list' then 'accounting.view'
    when 'finance.propose' then case input->>'action'
      when 'payment.record' then 'payments.create' when 'expense.record' then 'expenses.create'
      when 'invoice.amend' then 'invoices.edit' when 'income.record' then 'accounting.create' end
    when 'proposal.get' then case (select action from public.agent_proposals where id::text=input->>'id' and connection_id=c.id)
      when 'payment.record' then 'payments.create' when 'expense.record' then 'expenses.create'
      when 'invoice.amend' then 'invoices.edit' when 'income.record' then 'accounting.create' end
    when 'connection.check' then '' end;
  if required is null or (required<>'' and not public.agent_has_permission(c.owner_id,required))
    or (c.kind='customer_care' and p_action not in ('connection.check','shipment.track'))
  then
    insert into public.agent_activity(connection_id,action,outcome) values(c.id,left(p_action,80),'denied');
    return jsonb_build_object('code','forbidden');
  end if;
  if p_action='connection.check' then
    out_data := jsonb_build_object('id',c.id,'kind',c.kind,'expiresAt',c.expires_at,'financeMode','staff_approval');
  elsif p_action='shipment.track' then
    if length(input->>'number') not between 5 and 40 then return jsonb_build_object('code','invalid_input'); end if;
    out_data := public.track_shipment(input->>'number');
  elsif p_action in ('invoice.get','invoice.pdf') then
    select * into s from public.shipments where upper(tracking_number)=upper(btrim(input->>'number')) and voided_at is null and invoice_finalized_at is not null;
    if s.id is not null then
      out_data := jsonb_build_object('shipmentId',s.id,'number',s.tracking_number,'invoiceNumber',s.invoice_number,
        'currency',coalesce(s.invoice_currency,s.currency),'grossAmount',(s.invoice_amount+coalesce(s.discount,0)),'discount',s.discount,
        'amount',s.invoice_amount,'amountPaid',s.amount_paid,'finalizedAt',s.invoice_finalized_at,'updatedAt',s.updated_at,
        'customer',(select jsonb_build_object('name',name,'company',company,'address',address) from public.customers where id=s.customer_id),
        'company',(select jsonb_build_object('name',company_name,'address',address,'phone',phone,'email',email,'taxId',tax_id) from public.company_settings where id='default'),
        'charges',coalesce((select jsonb_agg(jsonb_build_object('type',charge_type,'description',custom_label,'amount',amount,'currency',currency)) from public.cargo_extra_charges where shipment_id=s.id and status='ACTIVE' and charge_direction='billable_to_customer'),'[]'::jsonb));
    end if;
  elsif p_action='accounts.list' then
    out_data := coalesce((select jsonb_agg(jsonb_build_object('code',code,'name',name,'type',account_type,'manual',allow_manual_posting) order by code) from public.accounting_accounts where active),'[]'::jsonb);
  elsif p_action='proposal.get' then
    select * into q from public.agent_proposals where id::text=input->>'id' and connection_id=c.id;
    if q.id is not null then out_data:=jsonb_build_object('id',q.id,'status',q.status,'expiresAt',q.expires_at,'decidedAt',q.decided_at,'reason',q.decision_reason); end if;
  elsif p_action='finance.propose' then
    if p_idempotency_key is null or jsonb_typeof(input->'payload') is distinct from 'object' then return jsonb_build_object('code','invalid_input'); end if;
    select * into q from public.agent_proposals where connection_id=c.id and idempotency_key=p_idempotency_key;
    if q.id is not null then
      if q.action is distinct from input->>'action' or q.payload is distinct from input->'payload' then return jsonb_build_object('code','idempotency_conflict'); end if;
    else
      target := nullif(input->'payload'->>'shipmentId','');
      if input->>'action' in ('payment.record','invoice.amend') and target is null then return jsonb_build_object('code','invalid_input'); end if;
      if target is not null then
        select * into s from public.shipments where id=target and voided_at is null;
        if s.id is null then return jsonb_build_object('code','not_found'); end if;
        snap := encode(sha256(convert_to(to_jsonb(s)::text,'UTF8')),'hex');
      end if;
      insert into public.agent_proposals(connection_id,idempotency_key,action,payload,shipment_id,snapshot_hash)
      values(c.id,p_idempotency_key,input->>'action',input->'payload',target,snap) returning * into q;
    end if;
    out_data := jsonb_build_object('id',q.id,'status',q.status,'expiresAt',q.expires_at);
  end if;
  insert into public.agent_activity(connection_id,action,outcome) values(c.id,p_action,case when out_data is null then 'not_found' else 'success' end);
  if out_data is null then return jsonb_build_object('code','not_found'); end if;
  return jsonb_build_object('data',out_data);
end $$;

create function public.decide_agent_proposal(p_id uuid, p_approve boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare q public.agent_proposals; c public.agent_connections; s public.shipments;
  v jsonb; r jsonb; required text; actor uuid := auth.uid();
begin
  -- Lock both proposal and connection, so approval and revocation serialize.
  select * into q from public.agent_proposals where id=p_id for update;
  if q.id is null then raise exception 'Proposal not found.'; end if;
  select * into c from public.agent_connections where id=q.connection_id for update;
  required := case q.action when 'payment.record' then 'payments.create' when 'expense.record' then 'expenses.create' when 'invoice.amend' then 'invoices.edit' when 'income.record' then 'accounting.create' end;
  if not public.agent_has_permission(actor,required) then raise exception 'You do not have permission to review this operation.'; end if;
  if q.status<>'PENDING' then return jsonb_build_object('id',q.id,'status',q.status); end if;
  if p_approve is null or nullif(btrim(p_reason),'') is null or length(p_reason)>2000 then raise exception 'A review decision and reason (up to 2000 characters) are required.'; end if;
  if p_approve then
    if c.revoked_at is not null or c.expires_at<=now() or q.expires_at<=now() or not public.agent_has_permission(c.owner_id,required) then raise exception 'Connection or proposal is expired, revoked or no longer authorized.'; end if;
    -- Existing finance RPCs enforce Admin/Manager posting. Keep that boundary.
    if not exists(select 1 from public.staff_profiles where id=actor and role in ('Admin','Manager') and active and not must_change_password) then raise exception 'Posting requires an active Manager or Admin.'; end if;
    if q.shipment_id is not null then
      select * into s from public.shipments where id=q.shipment_id for update;
      if q.snapshot_hash is distinct from encode(sha256(convert_to(to_jsonb(s)::text,'UTF8')),'hex') then raise exception 'Shipment changed since proposal. Reject and request a fresh proposal.'; end if;
    end if;
    v := q.payload;
    if q.action='payment.record' then
      r := public.record_payment(q.shipment_id,(v->>'amount')::numeric,v->>'currency',v->>'method',(v->>'date')::date,v->>'note',q.id,
        case when v->>'method'='Cash' then '1000' else '1010' end);
    elsif q.action='expense.record' then
      r := public.record_expense(q.id,(v->>'date')::date,v->>'category',v->>'description',(v->>'amount')::numeric,v->>'currency',v->>'expenseAccountCode',v->>'method',
        case when v->>'method'='Cash' then '1000' else '1010' end,v->>'payee',v->>'reference',q.shipment_id,v->>'note');
    elsif q.action='invoice.amend' then
      r := public.amend_invoice(q.shipment_id,(v->>'grossAmount')::numeric,(v->>'discount')::numeric,v->>'discountReason',v->>'reason');
    elsif q.action='income.record' then
      r := to_jsonb(public.create_other_income((v->>'date')::date,v->>'incomeAccountCode',v->>'receivingAccountCode',v->>'description',(v->>'amount')::numeric,v->>'currency',(v->>'exchangeRate')::numeric,v->>'reference'));
    end if;
  end if;
  update public.agent_proposals set status=case when p_approve then 'APPROVED' else 'REJECTED' end,decided_by=actor,decided_at=now(),decision_reason=btrim(p_reason),result=r where id=q.id;
  insert into public.agent_activity(connection_id,action,outcome) values(c.id,q.action,case when p_approve then 'approved' else 'rejected' end);
  insert into public.business_audit_log(action,entity_type,entity_id,actor_id,actor_name,details)
  select case when p_approve then 'AGENT_PROPOSAL_APPROVED' else 'AGENT_PROPOSAL_REJECTED' end,'agent_proposal',q.id::text,actor,name,jsonb_build_object('connection_id',c.id,'action',q.action,'reason',btrim(p_reason)) from public.staff_profiles where id=actor;
  return jsonb_build_object('id',q.id,'status',case when p_approve then 'APPROVED' else 'REJECTED' end);
end $$;

revoke all on function public.guard_agent_owner_permissions(),public.agent_has_permission(uuid,text),public.agent_is_admin(uuid),public.create_agent_connection(text,text,timestamptz),public.revoke_agent_connection(uuid),public.agent_api_request(text,text,jsonb,uuid),public.decide_agent_proposal(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.agent_has_permission(uuid,text),public.agent_is_admin(uuid),public.create_agent_connection(text,text,timestamptz),public.revoke_agent_connection(uuid),public.decide_agent_proposal(uuid,boolean,text) to authenticated;
grant execute on function public.agent_api_request(text,text,jsonb,uuid) to service_role;
commit;

