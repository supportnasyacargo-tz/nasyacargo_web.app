export const ACTIONS = ['connection.check','shipment.track','invoice.get','invoice.pdf','accounts.list','finance.propose','proposal.get'] as const
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const FIELDS: Record<string, string[]> = {
  'payment.record': ['shipmentId','amount','currency','method','date','note'],
  'expense.record': ['shipmentId','amount','currency','method','date','note','category','description','expenseAccountCode','payee','reference'],
  'invoice.amend': ['shipmentId','grossAmount','discount','discountReason','reason'],
  'income.record': ['amount','currency','date','description','incomeAccountCode','receivingAccountCode','exchangeRate','reference'],
}
function object(v: unknown): v is Record<string, unknown> { return !!v && typeof v==='object' && !Array.isArray(v) }
function text(v: unknown): v is string { return typeof v==='string' && v.trim().length>0 && v.length<=2000 }
function positive(v: unknown) { return typeof v==='number' && Number.isFinite(v) && v>0 && v<=999999999 }

export function validateAgentRequest(body: unknown): string | null {
  if (!object(body) || Object.keys(body).some(k=>!['action','input','idempotencyKey'].includes(k))) return 'Invalid request.'
  if (!(ACTIONS as readonly unknown[]).includes(body.action)) return 'Unsupported action.'
  const input=body.input??{}
  if (!object(input)) return 'Input must be an object.'
  if (body.action==='finance.propose') {
    if (typeof body.idempotencyKey!=='string' || !UUID.test(body.idempotencyKey)) return 'A UUID idempotencyKey is required.'
    if (Object.keys(input).some(k=>!['action','payload'].includes(k)) || typeof input.action!=='string' || !FIELDS[input.action] || !object(input.payload)) return 'Unsupported finance proposal.'
    const p=input.payload
    if (Object.keys(p).some(k=>!FIELDS[input.action as string].includes(k))) return 'Unknown proposal field.'
    if (Object.values(p).some(v=>typeof v==='string' && v.length>2000)) return 'Text field is too long.'
    if (['payment.record','invoice.amend'].includes(input.action) && !text(p.shipmentId)) return 'shipmentId is required.'
    if (input.action==='invoice.amend') {
      if (!positive(p.grossAmount) || typeof p.discount!=='number' || !Number.isFinite(p.discount) || p.discount<0 || p.discount>=Number(p.grossAmount) || !text(p.reason) || (p.discount>0&&!text(p.discountReason))) return 'Valid grossAmount, discount and correction reasons are required.'
    } else {
      if (!positive(p.amount) || !['USD','TZS','AED'].includes(String(p.currency))) return 'Valid amount and currency are required.'
      if (typeof p.date!=='string' || !/^\d{4}-\d{2}-\d{2}$/.test(p.date) || !Number.isFinite(Date.parse(p.date)) || new Date(p.date).toISOString().slice(0,10)!==p.date) return 'Valid date is required.'
      if (input.action!=='income.record' && !['Cash','Bank Transfer','M-Pesa','Card','Other'].includes(String(p.method))) return 'Valid payment method is required.'
      if (['expense.record','income.record'].includes(input.action) && !text(p.description)) return 'Description is required.'
      if (input.action==='expense.record' && (!text(p.category) || !/^\d{4}$/.test(String(p.expenseAccountCode)))) return 'Expense category and account code are required.'
      if (input.action==='income.record' && (!positive(p.exchangeRate) || !/^\d{4}$/.test(String(p.incomeAccountCode)) || !['1000','1010'].includes(String(p.receivingAccountCode)))) return 'Income accounts and exchange rate are required.'
    }
  } else if (['shipment.track','invoice.get','invoice.pdf'].includes(String(body.action))) {
    if (Object.keys(input).some(k=>k!=='number') || typeof input.number!=='string' || !/^[a-z0-9-]{5,40}$/i.test(input.number.trim())) return 'Valid shipment number is required.'
  } else if (body.action==='proposal.get') {
    if (Object.keys(input).some(k=>k!=='id') || typeof input.id!=='string' || !UUID.test(input.id)) return 'Valid proposal id is required.'
  } else if (Object.keys(input).length) return 'This action takes no input.'
  return null
}

