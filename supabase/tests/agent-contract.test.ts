import test from 'node:test'
import assert from 'node:assert/strict'
import { validateAgentRequest } from '../functions/_shared/agent-contract.ts'
const id='00000000-0000-4000-8000-000000000001'
function proposal(action:string,payload:Record<string,unknown>){return {action:'finance.propose',idempotencyKey:id,input:{action,payload}}}
test('customer care tracks exact references, without arbitrary filters',()=>{
  assert.equal(validateAgentRequest({action:'shipment.track',input:{number:'nasya-261015-0001'}}),null)
  assert.ok(validateAgentRequest({action:'shipment.track',input:{number:'TEST-1',table:'staff_profiles'}}))
  assert.ok(validateAgentRequest({action:'staff.delete'}))
  assert.ok(validateAgentRequest({action:'sql',input:{query:'select 1'}}))
})
test('finance proposals require stable idempotency and reject invalid amounts',()=>{
  const valid=proposal('payment.record',{shipmentId:'synthetic',amount:10,currency:'USD',method:'Cash',date:'2026-10-15'})
  assert.equal(validateAgentRequest(valid),null)
  assert.ok(validateAgentRequest({...valid,idempotencyKey:undefined}))
  for(const amount of [0,-1,Infinity,NaN,'10'])assert.ok(validateAgentRequest(proposal('payment.record',{...valid.input.payload,amount})))
  assert.ok(validateAgentRequest(proposal('payment.record',{...valid.input.payload,date:'2026-02-31'})))
})
test('invoice correction needs reasons and cannot discount the entire amount',()=>{
  assert.equal(validateAgentRequest(proposal('invoice.amend',{shipmentId:'synthetic',grossAmount:50,discount:5,discountReason:'Agreed adjustment',reason:'Correction'})),null)
  assert.ok(validateAgentRequest(proposal('invoice.amend',{shipmentId:'synthetic',grossAmount:50,discount:50,reason:'Correction'})))
  assert.ok(validateAgentRequest(proposal('invoice.amend',{shipmentId:'synthetic',grossAmount:50,discount:5,reason:'Correction'})))
})
test('agents cannot request approval, change actors or supply arbitrary RPC fields',()=>{
  assert.ok(validateAgentRequest({action:'proposal.approve',input:{id}}))
  assert.ok(validateAgentRequest(proposal('expense.record',{amount:10,currency:'USD',date:'2026-10-15',description:'Synthetic',category:'Other',method:'Cash',expenseAccountCode:'5200',approved:true})))
  assert.ok(validateAgentRequest({...proposal('income.record',{}),ownerId:id}))
})

