
const args = process.argv.slice(2);
const deny = args[0] === "--deny";
const child = Bun.spawn(args.slice(args.indexOf("--") + 1), { stdin: "ignore", stdout: "pipe", stderr: "inherit" });
const decoder = new TextDecoder();
let pending = "";
for await (const chunk of child.stdout) {
  const text = decoder.decode(chunk, { stream: true });
  process.stdout.write(text);
  pending += text;
  for (let nl = pending.indexOf("\n"); nl >= 0; nl = pending.indexOf("\n")) {
    const line = pending.slice(0, nl);
    pending = pending.slice(nl + 1);
    let url: unknown;
    try {
      url = JSON.parse(line).authorize;
    } catch {}
    if (typeof url !== "string") continue;
    const back = new URL((await fetch(url, { redirect: "manual" })).headers.get("location") ?? "");
    if (deny) {
      back.searchParams.delete("code");
      back.searchParams.set("error", "access_denied");
    }
    await fetch(back);
  }
}
process.exit(await child.exited);
