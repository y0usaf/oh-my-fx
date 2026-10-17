import { fileURLToPath } from 'node:url'

export default defineNuxtConfig({
  compatibilityDate: '2026-09-07',
  devtools: { enabled: false },
  nitro: {
    externals: { inline: [fileURLToPath(new URL('../shared/', import.meta.url))] },
  },
})
