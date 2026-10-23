import { adminClient, bearerToken } from '../_shared/supabase.ts'
import { validateAgentRequest } from '../_shared/agent-contract.ts'
import { jsPDF } from 'npm:jspdf@4.2.1'

function reply(body: unknown, status=200, extra: Record<string,string>={}) {
  return new Response(JSON.stringify(body), {status,headers:{'Content-Type':'application/json','Cache-Control':'no-store',...extra}})
}

export async function handleAgentRequest(request: Request): Promise<Response> {
  if (request.method!=='POST') return reply({code:'method_not_allowed'},405,{Allow:'POST'})
  const token=bearerToken(request)
  if (!token || !/^tca_[0-9a-f]{64}$/.test(token)) return reply({code:'unauthorized'},401)
  // Read a bounded stream before parsing; Content-Length alone is untrusted.
  const reader=request.body?.getReader()
  if (!reader) return reply({code:'invalid_input'},400)
  const chunks: Uint8Array[]=[]; let size=0
  while (true) {
    const {done,value}=await reader.read(); if(done) break
    size+=value.byteLength
    if(size>16384){await reader.cancel();return reply({code:'payload_too_large'},413)}
    chunks.push(value)
  }
  let body: {action:string; input?:Record<string,unknown>; idempotencyKey?:string}
  try {
    const bytes=new Uint8Array(size); let offset=0
    for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length}
    body=JSON.parse(new TextDecoder().decode(bytes))
  } catch {return reply({code:'invalid_json'},400)}
  const validation=validateAgentRequest(body)
  if(validation) return reply({code:'invalid_input',message:validation},400)
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(token))
  const hash=Array.from(new Uint8Array(digest),v=>v.toString(16).padStart(2,'0')).join('')
  try {
    const {data,error}=await adminClient().rpc('agent_api_request',{p_token_hash:hash,p_action:body.action,p_input:body.input??{},p_idempotency_key:body.idempotencyKey??null})
    if(error) return reply({code:'backend_unavailable',message:'The request could not be completed.'},502)
    if(data?.code) return reply(data,({unauthorized:401,forbidden:403,rate_limited:429,invalid_input:400,not_found:404,idempotency_conflict:409} as Record<string,number>)[data.code]??400,data.code==='rate_limited'?{'Retry-After':'60'}:{})
    if(body.action==='invoice.pdf') {
      const v=data.data
      // Snapshot export: no new invoice, prices or accounting entries are created.
      const pdf=new jsPDF(); let y=18
      function line(value: unknown, bold=false) {
        const lines=pdf.splitTextToSize(String(value??''),174)
        for(const item of lines){if(y>278){pdf.addPage();y=18}pdf.setFont('helvetica',bold?'bold':'normal');pdf.setFontSize(11);pdf.text(item,18,y);y+=7}
      }
      line(v.company?.name||'Nasya Cargo',true);line(v.company?.address);line(v.company?.phone);line(v.company?.email)
      y+=6;line(`Invoice ${v.invoiceNumber||v.number}`,true);line(`Shipment: ${v.number}`);line(`Finalized: ${v.finalizedAt}`)
      line(`Customer: ${v.customer?.name??''}`);line(v.customer?.company);line(v.customer?.address)
      y+=5;line(`Gross: ${v.currency} ${v.grossAmount}`);line(`Discount: ${v.currency} ${v.discount}`);line(`Net invoice: ${v.currency} ${v.amount}`,true)
      let charges=0
      for(const charge of v.charges){line(`${charge.description||charge.type}: ${charge.currency} ${charge.amount}`);charges+=Number(charge.amount)}
      line(`Total due: ${v.currency} ${Number(v.amount)+charges}`,true);line(`Recorded paid: ${v.currency} ${v.amountPaid}`)
      line('Exported from the finalized app invoice. Payment status reflects recorded entries only.')
      const filename=String(v.invoiceNumber||v.number).replace(/[^A-Za-z0-9-]/g,'_')+'.pdf'
      return new Response(pdf.output('arraybuffer'),{headers:{'Content-Type':'application/pdf','Content-Disposition':`attachment; filename="${filename}"`,'Cache-Control':'no-store'}})
    }
    return reply(data)
  } catch {return reply({code:'backend_unavailable'},502)}
}
if (import.meta.main) Deno.serve(handleAgentRequest)

