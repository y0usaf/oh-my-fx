import { local } from "../durable/local.mjs";
import { world } from "../durable/world.mjs";

const { createWorld } = await import(new URL("../durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
const opened = [];

export async function appWorldAt(dir, options = {}) {
  const { world: _create, owned: _owned, name: _name, ...settings } = local({ dir, ...options });
  const instance = createWorld({ dataDir: dir, recoverActiveRuns: false });
  await instance.start();
  opened.push(instance);
  return world(instance, { name: "app", ...settings });
}

export async function closeAppWorlds() {
  for (const instance of opened.splice(0)) await instance.close().catch(() => {});
}
