// Credentials: real `fx mcp list --json`, `fx mcp logout` and `fx mcp login`
// runs against a scratch HOME (FX_DISABLE_KEYCHAIN=1, so the file backend),
// each command's effect on ~/.fx/mcp-credentials read back, and the trace
// checked against Credentials.tla through CredentialsTrace.tla. No server is
// contacted: list never connects, these logins have no revocation endpoint,
// and a login on an unreadable store stops before it opens a listener.
import { expect, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary } from "../lib/context";
import { fixture, fxEnv, observeStores, runFx, save, v1Entry, v2Path, writeProfile, writeV1, type Fixture } from "./driver";
import { checkTrace, type TraceRecord } from "./trace";

// Tests marked NEXT_MCP check the MCP host fixes from the next MCP-v2
// version, which src/core/mcp_host/ does not have yet. They run only with
// FX_TLA_NEXT_MCP=1.
const NEXT_MCP = process.env.FX_TLA_NEXT_MCP === "1";


const URL = "http://127.0.0.1:9/mcp";
const UNREADABLE = "fx can't read the saved MCP sign-ins in ~/.fx/mcp-credentials/credentials-v2.json. A newer fx saved them, or they're damaged; fix or delete them, then try again.\n";

function setup(name: string) {
  const f = fixture(artifacts, name);
  writeProfile(f, { web: { type: "http", url: URL } });
  return f;
}

class Session {
  records: TraceRecord[] = [];
  constructor(readonly f: Fixture) {}
  observe() {
    const o = observeStores(this.f);
    this.records.push({ event: "observe", data: o, at: Date.now() });
    return o;
  }
  async run(cmd: "get" | "logout" | "put", args: string[], server = "") {
    this.records.push({ event: "run", data: { cmd, server }, at: Date.now(), note: `fx ${args.join(" ")}` });
    const ran = await runFx(binary, this.f, args, fxEnv(this.f), 30_000);
    const o = this.observe();
    return { ran, o };
  }
  fault(cmd: "unreadable" | "repair" | "delete") {
    this.records.push({ event: "run", data: { cmd, server: "" }, at: Date.now() });
  }
  async check(initKinds: string[], initEntries: string[], initImported = [false, true]) {
    const verdict = await checkTrace({
      module: "Credentials", records: this.records, dir: join(this.f.base, "trace"),
      constants: {
        ObsNames: ["web"], ObsFaults: ["unreadable", "repair", "delete"], ObsInitKinds: initKinds, ObsInitEntries: initEntries,
        ObsInitImported: initImported, ObsInitMarked: [false], ObsInitV1: ["web"],
      },
    });
    save(join(this.f.base, "verdict.json"), verdict);
    return verdict;
  }
}

/** A newer fx's document: version 2, which this fx can't read. */
function rewriteAsVersion(f: Fixture, version: number) {
  const doc = JSON.parse(readFileSync(v2Path(f), "utf8"));
  writeFileSync(v2Path(f), JSON.stringify({ ...doc, version }), { mode: 0o600 });
}

test.skipIf(!NEXT_MCP)("control: v1's login is taken over once, and a logout stays (trace ACCEPTED)", async () => {
  const s = new Session(setup("cred-control"));
  writeV1(s.f, [v1Entry("web", URL)]);
  expect(s.observe()).toEqual({ kind: "absent", entries: [], imported: false, marked: false, v1: ["web"] });
  const list = await s.run("get", ["mcp", "list", "--json"]);
  expect(list.ran.code).toBe(0);
  expect(list.o).toEqual({ kind: "ok", entries: ["web"], imported: true, marked: true, v1: ["web"] });
  const out = await s.run("logout", ["mcp", "logout", "web"], "web");
  expect(out.ran.code).toBe(0);
  expect(out.ran.stdout).toBe("Signed out of web.\n");
  expect(out.o.entries).toEqual([]);
  const again = await s.run("get", ["mcp", "list", "--json"]);
  expect(again.o).toEqual({ kind: "ok", entries: [], imported: true, marked: true, v1: ["web"] });
  const verdict = await s.check(["absent"], []);
  expect(verdict.verdict).toBe("ACCEPTED");
}, 120_000);

test.skipIf(!NEXT_MCP)("a newer fx's store is never written over; sign-in and sign-out say why they can't, and the login is there once it's readable (trace ACCEPTED)", async () => {
  const s = new Session(setup("cred-unreadable"));
  const credential = JSON.stringify({ access: "kept-by-newer-fx", refresh: "r", expires_at_ms: null, token_endpoint: "http://127.0.0.1:9/token", revocation_endpoint: null, resource: URL, client_id: "c", client_secret: null, method: "none" });
  mkdirSync(join(s.f.home, ".fx", "mcp-credentials"), { recursive: true, mode: 0o700 });
  writeFileSync(v2Path(s.f), JSON.stringify({ version: 2, imported_v1: true, servers: [{ name: "web", url: URL, credential }] }), { mode: 0o600 });
  const before = readFileSync(v2Path(s.f), "utf8");
  save(join(s.f.base, "store-before.json"), before);
  expect(s.observe()).toEqual({ kind: "unreadable", entries: ["web"], imported: true, marked: false, v1: [] });

  // `fx mcp list` never connects; it reads web's credential to start the host.
  const list = await s.run("get", ["mcp", "list", "--json"]);
  expect(list.ran.code).toBe(0);
  const logout = await s.run("logout", ["mcp", "logout", "web"], "web");
  expect(logout.ran.code).toBe(1);
  expect(logout.ran.stderr).toBe(`Can't sign out of web: ${UNREADABLE}`);
  const login = await s.run("put", ["mcp", "login", "--no-browser", "web"], "web");
  expect(login.ran.code).toBe(1);
  expect(login.ran.stderr).toBe(`Can't sign in to web: ${UNREADABLE}`);
  // Independent oracle: the file is byte for byte what the newer fx wrote.
  save(join(s.f.base, "store-after.json"), readFileSync(v2Path(s.f), "utf8"));
  expect(readFileSync(v2Path(s.f), "utf8")).toBe(before);
  expect(login.o).toEqual({ kind: "unreadable", entries: ["web"], imported: true, marked: false, v1: [] });

  // Readable again (version 1), the login is still there and still used.
  rewriteAsVersion(s.f, 1);
  s.fault("repair");
  s.observe();
  const back = await s.run("get", ["mcp", "list", "--json"]);
  expect(back.o).toEqual({ kind: "ok", entries: ["web"], imported: true, marked: true, v1: [] });
  expect(readFileSync(v2Path(s.f), "utf8")).toContain("kept-by-newer-fx");
  const verdict = await s.check(["unreadable"], ["web"], [true]);
  expect(verdict.verdict).toBe("ACCEPTED");
}, 120_000);

test.skipIf(!NEXT_MCP)("a logout stays when the store becomes unreadable (trace ACCEPTED)", async () => {
  const s = new Session(setup("cred-undone"));
  writeV1(s.f, [v1Entry("web", URL)]);
  s.observe();
  await s.run("get", ["mcp", "list", "--json"]);
  const out = await s.run("logout", ["mcp", "logout", "web"], "web");
  expect(out.ran.stdout).toBe("Signed out of web.\n");
  expect(out.o.entries).toEqual([]);
  rewriteAsVersion(s.f, 2);
  s.fault("unreadable");
  const before = readFileSync(v2Path(s.f), "utf8");
  expect(s.observe().kind).toBe("unreadable");
  const back = await s.run("get", ["mcp", "list", "--json"]);
  const verdict = await s.check(["absent"], []);
  // Independent oracle: nothing was imported or written.
  expect(back.o).toEqual({ kind: "unreadable", entries: [], imported: true, marked: true, v1: ["web"] });
  expect(readFileSync(v2Path(s.f), "utf8")).toBe(before);
  expect(verdict.verdict).toBe("ACCEPTED");
}, 120_000);

test.skipIf(!NEXT_MCP)("deleting the v2 file doesn't bring back a login signed out of (trace ACCEPTED)", async () => {
  const s = new Session(setup("cred-deleted"));
  writeV1(s.f, [v1Entry("web", URL)]);
  s.observe();
  await s.run("get", ["mcp", "list", "--json"]);
  await s.run("logout", ["mcp", "logout", "web"], "web");
  rmSync(v2Path(s.f));
  s.fault("delete");
  s.observe();
  const back = await s.run("get", ["mcp", "list", "--json"]);
  const verdict = await s.check(["absent"], []);
  // Independent oracle: v1's copy stayed out, and only the note remains.
  expect(back.o.entries).toEqual([]);
  expect(back.o).toEqual({ kind: "absent", entries: [], imported: false, marked: true, v1: ["web"] });
  expect(verdict.verdict).toBe("ACCEPTED");
}, 120_000);
