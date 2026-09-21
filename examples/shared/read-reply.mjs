export async function* readReply(response) {
  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let finished = false
  try {
    while (!finished) {
      const { value, done } = await reader.read()
      finished = done
      const text = decoder.decode(value, { stream: !done })
      if (text) yield text
    }
  } finally {
    if (!finished) await reader.cancel().catch(() => {})
    reader.releaseLock()
  }
}
