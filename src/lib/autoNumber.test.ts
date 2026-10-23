import test from 'node:test'
import assert from 'node:assert/strict'
import { nextTrackingNumber, nextPackingListNumber } from './autoNumber.ts'

test('tracking numbers advance beyond the highest reference for today', () => {
  const first=nextTrackingNumber([])
  const stem=first.slice(0,-4)
  assert.equal(nextTrackingNumber([`${stem}0007`,`${stem}0002`]),`${stem}0008`)
  assert.match(first,/^NASYA-\d{6}-0001$/)
})
test('configured prefixes stay separate and packing counters advance',()=>{
  const first=nextTrackingNumber([],'TEST')
  assert.match(first,/^TEST-\d{6}-0001$/)
  assert.equal(nextTrackingNumber([first],'TEST'),first.slice(0,-4)+'0002')
  const packing=nextPackingListNumber([],'PL-TEST')
  assert.equal(nextPackingListNumber([packing],'PL-TEST'),packing.slice(0,-3)+'002')
})
