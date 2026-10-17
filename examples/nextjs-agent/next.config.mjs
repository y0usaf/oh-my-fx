import { fileURLToPath } from 'node:url'

const examplesRoot = fileURLToPath(new URL('..', import.meta.url))
export default {
  turbopack: { root: examplesRoot },
  outputFileTracingRoot: examplesRoot,
}
