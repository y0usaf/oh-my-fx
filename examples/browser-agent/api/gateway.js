import { errorResponse, gatewayFetch } from '../../shared/gateway.mjs'

export default {
  async fetch(request) {
    try {
      const path = new URL(request.url).searchParams.get('path')
      const paths = ['/coding-agent/v1/models', '/v4/ai/language-model']
      if (!paths.includes(path)) return new Response('Not found', { status: 404 })
      const upstream = await gatewayFetch(new Request(`https://ai-gateway.vercel.sh${path}`, request))
      return new Response(upstream.body, {
        status: upstream.status,
        headers: { 'content-type': upstream.headers.get('content-type') ?? 'text/plain', 'cache-control': 'no-store' },
      })
    } catch (error) {
      return errorResponse(error)
    }
  },
}
