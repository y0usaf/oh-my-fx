import { model } from './model.mjs'

function fail(status, message) {
  throw Object.assign(new Error(message), { status })
}

export async function readJson(request) {
  const reader = request.body?.getReader()
  if (!reader) fail(400, 'Send a JSON request body.')
  const chunks = []
  let size = 0
  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > 32768) {
        await reader.cancel()
        fail(413, 'This conversation is too long. Start a new one.')
      }
      chunks.push(value)
    }
  } finally {
    reader.releaseLock()
  }
  const bytes = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  try { return JSON.parse(new TextDecoder().decode(bytes)) }
  catch { fail(400, 'Send valid JSON.') }
}

export async function readPrompt(request) {
  const body = await readJson(request)
  const prompt = typeof body?.prompt === 'string' ? body.prompt.trim() : ''
  if (!prompt || prompt.length > 2000) fail(400, 'Enter a prompt of 1–2,000 characters.')
  return prompt
}

// All public examples share this transport policy; the agent code stays in each example.
export async function gatewayFetch(input, init) {
  const request = new Request(input, init)
  const url = new URL(request.url)
  const catalog = url.pathname === '/coding-agent/v1/models' && request.method === 'GET'
  const generation = url.pathname === '/v4/ai/language-model' && request.method === 'POST'
  if (url.origin !== 'https://ai-gateway.vercel.sh' || url.search || (!catalog && !generation)) {
    fail(404, 'Unknown model endpoint.')
  }
  const key = process.env.AI_GATEWAY_API_KEY
  if (!key) fail(503, 'The demo is not configured yet.')
  let body
  if (generation) {
    const input = await readJson(request)
    const prompt = input?.prompt
    if (!Array.isArray(prompt) || !prompt.length || prompt.length > 40) fail(400, 'Invalid conversation.')
    for (const message of prompt) {
      if (!message || !['system', 'user', 'assistant'].includes(message.role)) fail(400, 'Only text messages are supported.')
      if (message.role === 'system' && typeof message.content === 'string') continue
      if (!Array.isArray(message.content) || !message.content.every(
        (part) => part?.type === 'text' && typeof part.text === 'string',
      )) fail(400, 'Only text messages are supported.')
    }
    body = JSON.stringify({ prompt, maxOutputTokens: 512 })
  }
  const headers = new Headers({ authorization: `Bearer ${key}`, 'content-type': 'application/json' })
  if (generation) {
    headers.set('ai-language-model-id', model)
    headers.set('ai-language-model-streaming', 'true')
  }
  for (const name of ['ai-gateway-protocol-version', 'ai-language-model-specification-version']) {
    const value = request.headers.get(name)
    if (value) headers.set(name, value)
  }
  return fetch(new Request(url, {
    method: request.method, headers, body, redirect: 'error',
    signal: AbortSignal.any([request.signal, AbortSignal.timeout(30000)]),
  }))
}

export function errorResponse(error) {
  const status = Number.isInteger(error?.status) ? error.status : 502
  return new Response(status < 500 ? error.message : 'The demo could not respond. Try again shortly.', {
    status, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
  })
}
