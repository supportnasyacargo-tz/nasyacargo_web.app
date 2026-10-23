import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useAuthStore } from '../store/useAuthStore'
import { useAppStore } from '../store/useAppStore'
import { useAccountingStore } from '../store/useAccountingStore'
import { hasPermission, type PermissionCode } from '../lib/permissions'

interface Connection { id:string; name:string; kind:string; token_prefix:string; expires_at:string; revoked_at:string|null; last_used_at:string|null }
interface Proposal { id:string; connection_id:string; action:string; payload:Record<string,unknown>; status:string; created_at:string; expires_at:string; decision_reason:string|null }
const PERMISSION:Record<string,PermissionCode>={'payment.record':'payments.create','expense.record':'expenses.create','invoice.amend':'invoices.edit','income.record':'accounting.create'}
const LABELS:Record<string,string>={shipmentId:'Shipment ID',amount:'Amount',currency:'Currency',method:'Payment method',date:'Date',note:'Notes',category:'Expense category',description:'Description',expenseAccountCode:'Expense account',payee:'Payee',reference:'Reference',grossAmount:'Gross invoice amount',discount:'Discount',discountReason:'Discount reason',reason:'Correction reason',incomeAccountCode:'Income account',receivingAccountCode:'Receiving account',exchangeRate:'Exchange rate'}
const OPERATIONS:Record<string,string>={'payment.record':'Record payment','expense.record':'Record expense','invoice.amend':'Amend invoice','income.record':'Record other income'}

export default function AgentConnections() {
  const user=useAuthStore(s=>s.currentUser)
  const [connections,setConnections]=useState<Connection[]>([])
  const [proposals,setProposals]=useState<Proposal[]>([])
  const [name,setName]=useState('')
  const [kind,setKind]=useState('customer_care')
  const [secret,setSecret]=useState('')
  const [reason,setReason]=useState<Record<string,string>>({})
  const [busy,setBusy]=useState(false)
  const [message,setMessage]=useState('')
  const admin=user?.role==='Admin'
  const can=(p:PermissionCode)=>hasPermission(user?.role,p,user?.permissionsMode,user?.permissions)
  async function load() {
    const results=await Promise.all([
      admin?supabase.from('agent_connections').select('id,name,kind,token_prefix,expires_at,revoked_at,last_used_at').order('created_at',{ascending:false}):Promise.resolve({data:[],error:null}),
      supabase.from('agent_proposals').select('id,connection_id,action,payload,status,created_at,expires_at,decision_reason').order('created_at',{ascending:false}).limit(100),
    ])
    if(results.some(r=>r.error)) throw new Error('Agent access is not available yet. Apply the agent migration and deploy the API before connecting n8n.')
    setConnections(results[0].data as Connection[]);setProposals(results[1].data as Proposal[])
  }
  useEffect(()=>{void load().catch(e=>setMessage(e.message));return()=>setSecret('')},[admin])
  async function run(work:()=>Promise<void>) {
    setBusy(true);setMessage('')
    try{await work();await load()}catch(e){setMessage(e instanceof Error?e.message:'Request failed.')}finally{setBusy(false)}
  }
  async function create() {
    setSecret('')
    await run(async()=>{
      const {data,error}=await supabase.rpc('create_agent_connection',{p_name:name.trim(),p_kind:kind,p_expires_at:new Date(Date.now()+30*86400000).toISOString()})
      if(error)throw new Error(error.message)
      setSecret(data.secret);setName('')
    })
  }
  async function decide(p:Proposal,approve:boolean) {
    await run(async()=>{
      const {error}=await supabase.rpc('decide_agent_proposal',{p_id:p.id,p_approve:approve,p_reason:reason[p.id]?.trim()})
      if(error)throw new Error(error.message)
      await Promise.all([useAppStore.getState().loadAll(),useAccountingStore.getState().loadAccounting()])
    })
  }
  const endpoint=import.meta.env.VITE_SUPABASE_URL?`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/agent-api`:''
  return <div className="space-y-6">
    <section className="premium-card p-5"><h1 className="text-xl font-bold text-slate-900">Agents & approvals</h1><p className="mt-2 text-sm text-slate-600">Connect n8n customer care and finance agents. Finance requests stay pending until staff reviews and posts them.</p>{endpoint&&<p className="mt-3 break-all rounded bg-slate-50 p-3 font-mono text-xs">{endpoint}</p>}</section>
    {message&&<div role="alert" className="rounded-xl bg-amber-50 p-4 text-sm text-amber-900">{message}</div>}
    {admin&&<section className="premium-card space-y-4 p-5"><h2 className="font-bold">n8n connections</h2><form className="flex flex-wrap gap-3" onSubmit={e=>{e.preventDefault();void create()}}><input aria-label="Connection name" className="min-w-0 flex-1 rounded border p-3" placeholder="Connection name" required maxLength={80} value={name} onChange={e=>setName(e.target.value)}/><select aria-label="Agent access" className="rounded border p-3" value={kind} onChange={e=>setKind(e.target.value)}><option value="customer_care">Customer care · tracking only</option><option value="finance">Finance · read and propose</option></select><button disabled={busy} className="rounded bg-slate-900 px-4 py-3 text-white disabled:opacity-50">Create · 30 days</button></form>
      {secret&&<div className="rounded-xl border border-orange-200 bg-orange-50 p-4"><p className="text-sm font-semibold">Copy this key into an n8n Header Auth credential now. It is shown once.</p><code className="my-3 block break-all text-sm">{secret}</code><button className="rounded border px-3 py-2 text-sm" onClick={()=>setSecret('')}>I have saved the key</button></div>}
      {connections.map(c=><div key={c.id} className="flex flex-wrap items-center justify-between gap-3 border-t py-3"><div><strong>{c.name}</strong><div className="text-xs text-slate-500">{c.kind==='finance'?'Finance':'Customer care'} · {c.token_prefix}… · expires {new Date(c.expires_at).toLocaleDateString()} · {c.revoked_at?'Revoked':new Date(c.expires_at)<new Date()?'Expired':'Active'}</div></div>{!c.revoked_at&&<button disabled={busy} className="rounded border border-red-200 px-3 py-2 text-sm text-red-700" onClick={()=>void run(async()=>{const {error}=await supabase.rpc('revoke_agent_connection',{p_id:c.id});if(error)throw new Error(error.message)})}>Revoke access</button>}</div>)}
    </section>}
    <section className="premium-card p-5"><div className="flex items-center justify-between"><h2 className="font-bold">Finance proposals · latest 100</h2><button disabled={busy} className="rounded border px-3 py-2 text-sm" onClick={()=>void run(async()=>{})}>Refresh</button></div><p className="my-3 text-sm text-slate-600">Verify the amounts, account, date and evidence before approving. Posting requires Manager or Admin access. Changed shipments require a fresh proposal.</p>{proposals.length===0&&<p className="py-5 text-sm text-slate-500">No proposals yet.</p>}
      {proposals.map(p=><article key={p.id} className="mt-4 rounded-xl border p-4"><div className="flex flex-wrap justify-between gap-2"><h3 className="font-bold">{OPERATIONS[p.action]||p.action}</h3><span className="text-sm font-semibold">{p.status}{p.status==='PENDING'&&new Date(p.expires_at)<new Date()?' · Expired':''}</span></div><p className="mt-1 text-xs text-slate-500">{connections.find(c=>c.id===p.connection_id)?.name||'Finance agent'} · {new Date(p.created_at).toLocaleString()}</p><dl className="my-4 grid gap-2 sm:grid-cols-2">{Object.entries(p.payload).map(([key,value])=><div key={key}><dt className="text-xs text-slate-500">{LABELS[key]||key}</dt><dd className="break-words text-sm font-medium">{String(value??'—')}</dd></div>)}</dl>
        {p.status==='PENDING'&&can(PERMISSION[p.action])?<div className="space-y-3"><label className="block text-sm">Review reason<input className="mt-1 w-full rounded border p-3" maxLength={2000} value={reason[p.id]||''} onChange={e=>setReason({...reason,[p.id]:e.target.value})}/></label><div className="flex gap-2"><button disabled={busy||!reason[p.id]?.trim()||!['Admin','Manager'].includes(user?.role||'')||new Date(p.expires_at)<new Date()} className="rounded bg-emerald-700 px-4 py-2 text-sm text-white disabled:opacity-40" onClick={()=>void decide(p,true)}>Approve & post</button><button disabled={busy||!reason[p.id]?.trim()} className="rounded border px-4 py-2 text-sm disabled:opacity-40" onClick={()=>void decide(p,false)}>Reject</button></div></div>:p.decision_reason&&<p className="text-sm text-slate-600">Review: {p.decision_reason}</p>}
      </article>)}
    </section>
  </div>
}
