-- Isolated database only. Synthetic fixtures; everything is rolled back.
\set ON_ERROR_STOP on
begin;
insert into auth.users(id,email) values('11111111-1111-4111-8111-111111111111','agent-admin@synthetic.test'),('22222222-2222-4222-8222-222222222222','agent-staff@synthetic.test');
update public.staff_profiles set role='Admin',active=true,must_change_password=false where id='11111111-1111-4111-8111-111111111111';
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
insert into public.customers(id,name,created_at,updated_at) values('AGENT-CUSTOMER','Synthetic QA customer',now()::text,now()::text);
insert into public.exchange_rates(rate_date,usd_to_tzs,usd_to_aed,created_by) values(current_date,2700,3.67,'11111111-1111-4111-8111-111111111111');
insert into public.shipments(id,tracking_number,status,shipment_type,cargo_category,service_type,customer_id,origin,destination,destination_city,weight_kg,pcs,total_amount,currency,base_currency,base_amount_usd,usd_to_tzs_rate_used,usd_to_aed_rate_used,invoice_currency,invoice_amount,invoice_number,invoice_finalized_at,created_by,created_at,updated_at)
values('AGENT-SHIP','QA-261015-0001','RECEIVED','Air Cargo','General Cargo','Air Cargo','AGENT-CUSTOMER','Synthetic origin','Synthetic country','Synthetic city',20,1,100,'USD','USD',100,2700,3.67,'USD',100,'QA-INV-0001',now(),'agent-admin@synthetic.test',now()::text,now()::text);
select public.post_invoice_accounting('AGENT-SHIP');

do $$
declare cc jsonb; fin jsonb; hcc text; hfin text; r jsonb; q uuid; v jsonb; key uuid:=gen_random_uuid(); n integer;
begin
  cc:=public.create_agent_connection('Synthetic care','customer_care',now()+interval '1 day');
  fin:=public.create_agent_connection('Synthetic finance','finance',now()+interval '1 day');
  if length(cc->>'secret')<>68 then raise exception 'FAIL token format'; end if;
  hcc:=encode(sha256(convert_to(cc->>'secret','UTF8')),'hex');
  hfin:=encode(sha256(convert_to(fin->>'secret','UTF8')),'hex');
  if (select token_hash from public.agent_connections where id=(cc->>'id')::uuid)<>hcc then raise exception 'FAIL digest'; end if;
  r:=public.agent_api_request('invalid','connection.check');
  if r->>'code'<>'unauthorized' then raise exception 'FAIL invalid token'; end if;
  r:=public.agent_api_request(hcc,'shipment.track','{"number":"qa-261015-0001"}');
  if r->'data'->>'shipmentNumber'<>'QA-261015-0001' then raise exception 'FAIL case-insensitive tracking'; end if;
  r:=public.agent_api_request(hcc,'invoice.get','{"number":"QA-261015-0001"}');
  if r->>'code'<>'forbidden' then raise exception 'FAIL care finance isolation'; end if;
  r:=public.agent_api_request(hcc,'finance.propose','{"action":"payment.record","payload":{}}',gen_random_uuid());
  if r->>'code'<>'forbidden' then raise exception 'FAIL care writes'; end if;
  r:=public.agent_api_request(hfin,'invoice.get','{"number":"QA-261015-0001"}');
  if (r->'data'->>'grossAmount')::numeric<>100 then raise exception 'FAIL invoice snapshot'; end if;
  if r::text like '%token_hash%' or r::text like '%internal_note%' then raise exception 'FAIL data leak'; end if;
  r:=public.agent_api_request(hfin,'accounts.list');
  if jsonb_array_length(r->'data')=0 then raise exception 'FAIL accounts'; end if;
  v:=jsonb_build_object('action','payment.record','payload',jsonb_build_object('shipmentId','AGENT-SHIP','amount',10,'currency','USD','method','Cash','date',current_date));
  r:=public.agent_api_request(hfin,'finance.propose',v,key);q:=(r->'data'->>'id')::uuid;
  if q is null then raise exception 'FAIL proposal creation'; end if;
  if exists(select 1 from public.payment_records where shipment_id='AGENT-SHIP') then raise exception 'FAIL agent posted without human'; end if;
  r:=public.agent_api_request(hfin,'finance.propose',v,key);
  if r->'data'->>'id'<>q::text then raise exception 'FAIL retry duplicated proposal'; end if;
  r:=public.agent_api_request(hfin,'finance.propose',jsonb_set(v,'{payload,amount}','11'),key);
  if r->>'code'<>'idempotency_conflict' then raise exception 'FAIL changed retry'; end if;
  perform set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
  begin
    perform public.decide_agent_proposal(q,true,'Synthetic unauthorized review');
    raise exception 'FAIL ordinary staff posted';
  exception when others then if sqlerrm not like '%Posting requires%' then raise; end if; end;
  perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
  r:=public.decide_agent_proposal(q,true,'Synthetic payment evidence verified');
  if r->>'status'<>'APPROVED' then raise exception 'FAIL approve'; end if;
  perform public.decide_agent_proposal(q,true,'Synthetic duplicate review');
  select count(*) into n from public.payment_records where shipment_id='AGENT-SHIP';
  if n<>1 then raise exception 'FAIL approval replay'; end if;
  if not exists(select 1 from public.payment_records where shipment_id='AGENT-SHIP' and status='POSTED' and amount=10) then raise exception 'FAIL posting'; end if;
  -- Each additional proposal is processed through its actual accounting RPC.
  v:=jsonb_build_object('action','expense.record','payload',jsonb_build_object('amount',5,'currency','USD','method','Cash','date',current_date,'category','Other','description','Synthetic QA expense','expenseAccountCode','5200'));
  r:=public.agent_api_request(hfin,'finance.propose',v,gen_random_uuid());q:=(r->'data'->>'id')::uuid;
  perform public.decide_agent_proposal(q,true,'Synthetic expense receipt verified');
  if not exists(select 1 from public.expenses where idempotency_key=q and status='POSTED') then raise exception 'FAIL atomic expense'; end if;
  v:=jsonb_build_object('action','invoice.amend','payload',jsonb_build_object('shipmentId','AGENT-SHIP','grossAmount',110,'discount',5,'discountReason','Synthetic discount','reason','Synthetic invoice correction'));
  r:=public.agent_api_request(hfin,'finance.propose',v,gen_random_uuid());q:=(r->'data'->>'id')::uuid;
  perform public.decide_agent_proposal(q,true,'Synthetic invoice correction verified');
  if (select invoice_amount from public.shipments where id='AGENT-SHIP')<>105 then raise exception 'FAIL amendment'; end if;
  v:=jsonb_build_object('action','income.record','payload',jsonb_build_object('amount',5,'currency','USD','date',current_date,'description','Synthetic income','incomeAccountCode','4090','receivingAccountCode','1000','exchangeRate',1));
  r:=public.agent_api_request(hfin,'finance.propose',v,gen_random_uuid());q:=(r->'data'->>'id')::uuid;
  perform public.decide_agent_proposal(q,true,'Synthetic income verified');
  select count(*) into n from public.other_income where description='Synthetic income';
  perform public.decide_agent_proposal(q,true,'Replay');
  if (select count(*) from public.other_income where description='Synthetic income')<>n or n<>1 then raise exception 'FAIL income replay'; end if;
  v:=jsonb_build_object('action','payment.record','payload',jsonb_build_object('shipmentId','AGENT-SHIP','amount',1,'currency','USD','method','Cash','date',current_date));
  r:=public.agent_api_request(hfin,'finance.propose',v,gen_random_uuid());q:=(r->'data'->>'id')::uuid;
  update public.shipments set updated_at='Synthetic changed snapshot' where id='AGENT-SHIP';
  begin
    perform public.decide_agent_proposal(q,true,'Stale approval');raise exception 'FAIL stale accepted';
  exception when others then if sqlerrm not like '%Shipment changed%' then raise; end if; end;
  perform public.decide_agent_proposal(q,false,'Stale proposal rejected');
  r:=public.agent_api_request(hfin,'proposal.get',jsonb_build_object('id',q));
  if r->'data'->>'status'<>'REJECTED' then raise exception 'FAIL reject poll'; end if;
  -- Expiry, forced password changes and revocation take effect per request.
  update public.staff_profiles set must_change_password=true where id='11111111-1111-4111-8111-111111111111';
  if public.agent_api_request(hfin,'connection.check')->>'code'<>'unauthorized' then raise exception 'FAIL forced password gate'; end if;
  perform set_config('request.jwt.claim.sub','',true);
  update public.staff_profiles set must_change_password=false where id='11111111-1111-4111-8111-111111111111';
  perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
  update public.agent_connections set expires_at=now()-interval '1 second' where id=(cc->>'id')::uuid;
  if public.agent_api_request(hcc,'connection.check')->>'code'<>'unauthorized' then raise exception 'FAIL expiry'; end if;
  update public.agent_connections set window_count=60,window_start=now() where id=(fin->>'id')::uuid;
  if public.agent_api_request(hfin,'connection.check')->>'code'<>'rate_limited' then raise exception 'FAIL rate limit'; end if;
  update public.agent_connections set window_count=0 where id=(fin->>'id')::uuid;
  r:=public.agent_api_request(hfin,'finance.propose',v,gen_random_uuid());q:=(r->'data'->>'id')::uuid;
  perform public.revoke_agent_connection((fin->>'id')::uuid);
  if public.agent_api_request(hfin,'connection.check')->>'code'<>'unauthorized' then raise exception 'FAIL revoke'; end if;
  begin
    perform public.decide_agent_proposal(q,true,'Revoked approval');raise exception 'FAIL revoked accepted';
  exception when others then if sqlerrm not like '%revoked%' then raise; end if; end;
  if exists(select 1 from public.journal_lines group by journal_entry_id having sum(debit)<>sum(credit)) then raise exception 'FAIL unbalanced ledger'; end if;
  if has_function_privilege('anon','public.agent_api_request(text,text,jsonb,uuid)','EXECUTE') or has_function_privilege('authenticated','public.agent_api_request(text,text,jsonb,uuid)','EXECUTE') then raise exception 'FAIL API privilege'; end if;
  if has_table_privilege('authenticated','public.agent_proposals','INSERT') or has_column_privilege('authenticated','public.agent_connections','token_hash','SELECT') then raise exception 'FAIL credential/queue privilege'; end if;
  raise notice 'PASS: scoped reads, digest storage, no direct posting, finance RPCs, approval replay, stale protection, expiry, revoke, rate limit, balanced journals and grants.';
end $$;

-- Exercise actual PostgreSQL roles and RLS, not only UI visibility.
set local role authenticated;
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
do $$
begin
  if exists(select 1 from public.agent_proposals where action<>'payment.record') then raise exception 'FAIL staff read other finance proposals'; end if;
  if exists(select 1 from public.agent_connections) then raise exception 'FAIL staff read connections'; end if;
  begin
    perform public.agent_api_request('invalid','connection.check');raise exception 'FAIL staff invoked service API';
  exception when insufficient_privilege then null; end;
  begin
    perform token_hash from public.agent_connections;raise exception 'FAIL hash readable';
  exception when insufficient_privilege then null; end;
  begin
    perform public.create_agent_connection('Unauthorized','finance',now()+interval '1 day');raise exception 'FAIL staff created access';
  exception when others then if sqlerrm not like '%Admin access%' then raise; end if; end;
  begin
    update public.staff_profiles set permissions_mode='CUSTOM',permissions=array['accounting.create'] where id=auth.uid();
  exception when others then if sqlerrm not like '%Admin can change%' then raise; end if; end;
  if exists(select 1 from public.staff_profiles where id=auth.uid() and permissions_mode='CUSTOM') then raise exception 'FAIL permission escalation'; end if;
  raise notice 'PASS: actual authenticated role, per-operation proposal RLS, secret column denial, service RPC denial and permission escalation denial.';
end $$;
reset role;
rollback;

