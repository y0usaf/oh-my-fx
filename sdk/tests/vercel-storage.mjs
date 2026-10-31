import { local } from "../durable/local.mjs";

const required = ["WORKFLOW_VERCEL_AUTH_TOKEN", "VERCEL_PROJECT_ID", "VERCEL_PROJECT_NAME", "VERCEL_TEAM_ID", "VERCEL_DEPLOYMENT_ID"];
const missing = required.filter((key) => !process.env[key]?.trim());
if (missing.length > 0) {
  throw new Error(`remote Vercel tests require ${missing.join(", ")}; the local api-workflow proxy needs a Vercel access token, not VERCEL_OIDC_TOKEN`);
}

const { createWorld } = await import(new URL("../durable/node_modules/@workflow/world-vercel/dist/index.js", import.meta.url).href);

/** `local()` with Vercel's World holding what `local()` keeps in files. */
export function vercelStorage(options) {
  const base = local(options);
  return {
    ...base,
    name: "vercel",
    world() {
      const queued = base.world();
      const { getRuntimeDeadline, ...stored } = createWorld({
        ...(process.env.WORKFLOW_VERCEL_AUTH_TOKEN ? { token: process.env.WORKFLOW_VERCEL_AUTH_TOKEN } : {}),
        projectConfig: {
          projectId: process.env.VERCEL_PROJECT_ID,
          projectName: process.env.VERCEL_PROJECT_NAME,
          teamId: process.env.VERCEL_TEAM_ID,
        },
      });
      return { ...stored, queue: queued.queue, createQueueHandler: queued.createQueueHandler, registerHandler: queued.registerHandler };
    },
  };
}
