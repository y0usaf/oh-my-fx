import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { POST } from './handler.mjs'

const html = await readFile(new URL('./index.html', import.meta.url))
const replyReader = await readFile(new URL('../shared/read-reply.mjs', import.meta.url))
createServer(async (incoming, outgoing) => {
  if (incoming.method === 'GET' && incoming.url === '/read-reply.mjs') {
    outgoing.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' }).end(replyReader)
    return
  }
  if (incoming.method === 'GET' && incoming.url === '/') {
    outgoing.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(html)
    return
  }
  if (incoming.method !== 'POST' || incoming.url !== '/api/chat') {
    outgoing.writeHead(404).end('Not found')
    return
  }
  const controller = new AbortController()
  outgoing.on('close', () => controller.abort())
  try {
    const request = new Request('http://localhost/api/chat', {
      method: 'POST', headers: incoming.headers, body: Readable.toWeb(incoming),
      duplex: 'half', signal: controller.signal,
    })
    const response = await POST(request)
    outgoing.writeHead(response.status, Object.fromEntries(response.headers))
    await pipeline(Readable.fromWeb(response.body), outgoing)
  } catch {
    outgoing.destroy()
  }
}).listen(Number(process.env.PORT ?? 3000))
