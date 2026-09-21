import assert from 'node:assert/strict'
import { test } from 'node:test'
import { readJson, readPrompt, gatewayFetch } from './gateway.mjs'

function setKey(t, key) {
  const previous = process.env.AI_GATEWAY_API_KEY
  if (key === undefined) delete process.env.AI_GATEWAY_API_KEY
  else process.env.AI_GATEWAY_API_KEY = key
  t.after(() => {
    if (previous === undefined) delete process.env.AI_GATEWAY_API_KEY
    else process.env.AI_GATEWAY_API_KEY = previous
  })
}

test('prompt validation trims text and rejects empty or oversized prompts', async () => {
  const request = (prompt) => new Request('https://demo.test/api/chat', {
    method: 'POST', body: JSON.stringify({ prompt }),
  })
  assert.equal(await readPrompt(request(' hello ')), 'hello')
  for (const prompt of ['', ' ', null, 123, 'x'.repeat(2001)]) {
    await assert.rejects(readPrompt(request(prompt)), { status: 400 })
  }
})

test('body limit counts streamed bytes even without content-length', async () => {
  let cancelled = false
  let chunks = 0
  const body = new ReadableStream({
    pull(controller) {
      if (chunks++ === 3) controller.close()
      else controller.enqueue(new Uint8Array(20000))
    },
    cancel() { cancelled = true },
  })
  const request = new Request('https://demo.test', { method: 'POST', body, duplex: 'half' })
  await assert.rejects(readJson(request), { status: 413 })
  assert.equal(cancelled, true)
})

test('invalid JSON is reported as a client error', async () => {
  await assert.rejects(readJson(new Request('https://demo.test', {
    method: 'POST', body: '{',
  })), { status: 400 })
})

test('gateway fixes the model and output limit without forwarding caller credentials or options', async (t) => {
  setKey(t, 'test-server-key')
  let upstream
  t.mock.method(globalThis, 'fetch', async (request) => {
    upstream = request
    return new Response('stream')
  })
  const prompt = [{ role: 'user', content: [{ type: 'text', text: 'Hi' }] }]
  const response = await gatewayFetch('https://ai-gateway.vercel.sh/v4/ai/language-model', {
    method: 'POST',
    headers: { authorization: 'Bearer caller-key', 'ai-language-model-id': 'expensive', cookie: 'private', 'ai-language-model-streaming': 'true', 'ai-language-model-specification-version': '4' },
    body: JSON.stringify({ prompt, maxOutputTokens: 50000, providerOptions: { tools: ['search'] } }),
  })
  assert.equal(await response.text(), 'stream')
  assert.equal(upstream.headers.get('authorization'), 'Bearer test-server-key')
  assert.equal(upstream.headers.get('ai-language-model-id'), 'openai/gpt-4.1-nano')
  assert.equal(upstream.headers.has('cookie'), false)
  assert.equal(upstream.headers.get('ai-language-model-specification-version'), '4')
  assert.deepEqual(await upstream.json(), { prompt, maxOutputTokens: 512 })
})

test('gateway refuses unknown destinations and non-text model inputs before transport', async (t) => {
  setKey(t, 'test-server-key')
  t.mock.method(globalThis, 'fetch', () => assert.fail('unexpected network request'))
  for (const url of ['https://example.test/', 'https://ai-gateway.vercel.sh/v1/credits']) {
    await assert.rejects(gatewayFetch(url), { status: 404 })
  }
  await assert.rejects(gatewayFetch('https://ai-gateway.vercel.sh/v4/ai/language-model', {
    method: 'POST', body: JSON.stringify({ prompt: [{ role: 'user', content: [{ type: 'image', image: 'https://example.test/image' }] }] }),
  }), { status: 400 })
})

test('gateway fails closed without the demo key', async (t) => {
  setKey(t, undefined)
  t.mock.method(globalThis, 'fetch', () => assert.fail('unexpected network request'))
  await assert.rejects(gatewayFetch('https://ai-gateway.vercel.sh/coding-agent/v1/models'), { status: 503 })
})
