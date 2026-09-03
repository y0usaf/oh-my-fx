let buffer = Buffer.alloc(0);
const calls = [];

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function handle(message) {
  if (message.method !== "fixture/call") return;
  calls.push(message);
  if (calls.length !== 2) return;

  for (const call of calls) {
    send({
      jsonrpc: "2.0",
      method: "notifications/progress",
      params: {
        progressToken: call.id,
        progress: 1,
        total: 2,
        message: `progress:${call.params.owner}`,
      },
    });
  }
  for (const call of calls.toReversed()) {
    send({
      jsonrpc: "2.0",
      id: call.id,
      result: { owner: call.params.owner },
    });
  }
}

process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const lineEnd = buffer.indexOf("\n");
    if (lineEnd < 0) return;
    const line = buffer.subarray(0, lineEnd).toString("utf8").replace(/\r+$/, "");
    buffer = buffer.subarray(lineEnd + 1);
    if (line.length > 0) handle(JSON.parse(line));
  }
});
