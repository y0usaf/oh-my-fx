import assert from 'node:assert/strict'
import { test } from 'node:test'
import { readReply } from './read-reply.mjs'

test('reads split UTF-8 without ReadableStream async iteration or pipeThrough', async () => {
  const bytes = new TextEncoder().encode('Hello, café 🌍')
  const body = new ReadableStream({
    start(controller) {
      for (const byte of bytes) controller.enqueue(Uint8Array.of(byte))
      controller.close()
    },
  })
  Object.defineProperties(body, {
    pipeThrough: { value: undefined },
    [Symbol.asyncIterator]: { value: undefined },
  })
  let reply = ''
  for await (const text of readReply({ body })) reply += text
  assert.equal(reply, 'Hello, café 🌍')
  assert.equal(body.locked, false)
})

test('flushes a partial character at the end of a response', async () => {
  const body = new ReadableStream({
    start(controller) { controller.enqueue(Uint8Array.of(0xc3)); controller.close() },
  })
  let reply = ''
  for await (const text of readReply({ body })) reply += text
  assert.equal(reply, '\ufffd')
})

test('releases the reader when the response fails', async () => {
  const body = new ReadableStream({ start(controller) { controller.error(new Error('disconnected')) } })
  await assert.rejects(async () => {
    for await (const text of readReply({ body })) void text
  }, /disconnected/)
  assert.equal(body.locked, false)
})

test('cancels the response when its consumer stops reading', async () => {
  let cancelled = false
  const body = new ReadableStream({
    pull(controller) { controller.enqueue(new TextEncoder().encode('hello')) },
    cancel() { cancelled = true },
  })
  for await (const text of readReply({ body })) {
    assert.equal(text, 'hello')
    break
  }
  assert.equal(cancelled, true)
  assert.equal(body.locked, false)
})
