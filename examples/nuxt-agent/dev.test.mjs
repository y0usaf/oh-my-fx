import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { cp, mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import test from 'node:test'

test('documented Nuxt dev setup loads the key and chat route', { timeout: 90000 }, async (t) => {
  const fixture = await mkdtemp(join(tmpdir(), 'fx-nuxt-dev-'))
  let server, stopped
  t.after(async () => {
    if (server && server.exitCode === null && server.signalCode === null) process.kill(-server.pid, 'SIGTERM')
    if (stopped) await stopped
    await rm(fixture, { recursive: true, force: true })
  })
  const app = join(fixture, 'nuxt-agent')
  await mkdir(app)
  for (const name of ['package.json', 'nuxt.config.ts', 'app', 'server']) {
    await cp(new URL(name, import.meta.url), join(app, name), { recursive: true })
  }
  await cp(new URL('../shared/', import.meta.url), join(fixture, 'shared'), { recursive: true })
  await symlink(new URL('node_modules/', import.meta.url), join(app, 'node_modules'), 'dir')
  await writeFile(join(app, '.env.local'), 'AI_GATEWAY_API_KEY=nuxt-dev-test-key\n')
  await writeFile(join(app, 'server/api/env.get.js'),
    "export default defineEventHandler(() => ({ loaded: process.env.AI_GATEWAY_API_KEY === 'nuxt-dev-test-key' }))\n")

  const socket = createServer().listen(0, '127.0.0.1')
  await once(socket, 'listening')
  const { port } = socket.address()
  await new Promise((resolve) => socket.close(resolve))
  const env = { ...process.env }
  delete env.AI_GATEWAY_API_KEY
  server = spawn('npm', ['run', 'dev', '--', '--host', '127.0.0.1', '--port', String(port)], {
    cwd: app, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
  })
  stopped = once(server, 'exit')
  let logs = ''
  for (const stream of [server.stdout, server.stderr]) {
    stream.on('data', (chunk) => { logs = (logs + chunk).slice(-8000) })
  }
  const base = `http://127.0.0.1:${port}`
  let response
  const deadline = Date.now() + 60000
  while (Date.now() < deadline) {
    try {
      response = await fetch(`${base}/api/env`, { signal: AbortSignal.timeout(1000) })
      if (response.ok) break
      await response.text()
    } catch {}
    assert.equal(server.exitCode, null, logs)
    await delay(100)
  }
  assert.ok(response?.ok, logs)
  await t.test('.env.local supplies the Gateway key', async () => {
    assert.deepEqual(await response.json(), { loaded: true })
  })
  await t.test('chat route imports shared code and validates prompts without a model request', async () => {
    const reply = await fetch(`${base}/api/chat`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ prompt: '' }), signal: AbortSignal.timeout(10000),
    })
    const text = await reply.text()
    assert.equal(reply.status, 400, text)
    assert.equal(text, 'Enter a prompt of 1–2,000 characters.')
  })
})
