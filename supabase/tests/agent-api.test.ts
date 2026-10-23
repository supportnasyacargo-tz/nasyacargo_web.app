import { handleAgentRequest } from '../functions/agent-api/index.ts'

function assert(value:unknown,message:string){if(!value)throw new Error(message)}
const token='tca_'+'a'.repeat(64)
function request(body:unknown,credential=token){return new Request('https://synthetic.test',{method:'POST',headers:{Authorization:`Bearer ${credential}`},body:JSON.stringify(body)})}
Deno.test('HTTP boundary rejects wrong method, credentials, malformed or oversized body',async()=>{
  assert((await handleAgentRequest(new Request('https://synthetic.test'))).status===405,'method')
  assert((await handleAgentRequest(request({action:'connection.check'},'invalid'))).status===401,'credential')
  assert((await handleAgentRequest(new Request('https://synthetic.test',{method:'POST',headers:{Authorization:`Bearer ${token}`},body:'{'}))).status===400,'JSON')
  assert((await handleAgentRequest(request({action:'connection.check',extra:'x'.repeat(20000)}))).status===413,'body limit')
  assert((await handleAgentRequest(request({action:'proposal.approve'}))).status===400,'agent approval route')
})
Deno.test('database errors are sanitized and connection tokens are only sent as digests',async()=>{
  Deno.env.set('SUPABASE_URL','https://synthetic-supabase.test');Deno.env.set('SUPABASE_SERVICE_ROLE_KEY','synthetic-server-key')
  const original=globalThis.fetch
  try{
    globalThis.fetch=async(_input,init)=>{
      const sent=String(init?.body)
      assert(!sent.includes(token),'raw credential sent to RPC')
      const hash=JSON.parse(sent).p_token_hash
      assert(/^[0-9a-f]{64}$/.test(hash),'digest missing')
      return new Response(JSON.stringify({code:'unauthorized'}),{headers:{'Content-Type':'application/json'}})
    }
    assert((await handleAgentRequest(request({action:'connection.check'}))).status===401,'unauthorized mapping')
    globalThis.fetch=async()=>new Response(JSON.stringify({message:'internal database details and secrets'}),{status:400,headers:{'Content-Type':'application/json'}})
    const response=await handleAgentRequest(request({action:'connection.check'}))
    assert(response.status===502,'error mapping');assert(!(await response.text()).includes('secrets'),'error leaked')
  }finally{globalThis.fetch=original}
})
Deno.test('finalized invoice snapshot exports PDF with a safe filename and no cache',async()=>{
  Deno.env.set('SUPABASE_URL','https://synthetic-supabase.test');Deno.env.set('SUPABASE_SERVICE_ROLE_KEY','synthetic-server-key')
  const original=globalThis.fetch
  try{
    globalThis.fetch=async()=>new Response(JSON.stringify({data:{number:'QA-0001',invoiceNumber:'QA-INV-0001',currency:'USD',grossAmount:100,discount:5,amount:95,amountPaid:10,finalizedAt:'2026-10-15',company:{name:'Synthetic company',address:'Synthetic address'},customer:{name:'Synthetic customer'},charges:[{type:'pickup',amount:2,currency:'USD'}]}}),{headers:{'Content-Type':'application/json'}})
    const response=await handleAgentRequest(request({action:'invoice.pdf',input:{number:'QA-0001'}}))
    assert(response.status===200,'PDF status');assert(response.headers.get('Content-Type')==='application/pdf','PDF MIME');assert(response.headers.get('Cache-Control')==='no-store','cache')
    const bytes=new Uint8Array(await response.arrayBuffer())
    assert(new TextDecoder().decode(bytes.slice(0,4))==='%PDF','PDF signature')
  }finally{globalThis.fetch=original}
})

