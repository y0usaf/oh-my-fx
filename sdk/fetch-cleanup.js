export const cleanupTimeoutMs = 100;
export const cleanupByteLimit = 64 * 1024;

export function fetchCleanupAction(state, maxAge = cleanupTimeoutMs, maxBytes = cleanupByteLimit) {
  if (state.eof) return "done";
  if (state.canceled || state.failed) return "abort";
  if (state.consumed) {
    return state.age >= maxAge || state.discarded >= maxBytes ? "abort" : "drain";
  }
  return state.alive && state.active && !state.closing ? "forward" : "abort";
}
