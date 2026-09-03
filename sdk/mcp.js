const maxTools = 64;
const maxInstructionsBytes = 64 * 1024;

function contentText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((item) => {
    if (item?.type === "text" && typeof item.text === "string") return item.text;
    if (item?.type === "resource" && typeof item.resource?.text === "string") return item.resource.text;
    if (typeof item?.text === "string") return item.text;
    return "";
  }).filter(Boolean).join("\n");
}

function resultText(result) {
  const text = contentText(result?.content);
  if (text) return text;
  if (result?.structuredContent !== undefined) return JSON.stringify(result.structuredContent);
  return "";
}

function appendInstruction(parts, label, text) {
  if (!text) return;
  parts.push(`<${label}>\n${text}\n</${label}>`);
}

export async function createMcpAdapter(client, options = {}) {
  if (!client || typeof client.listTools !== "function" || typeof client.callTool !== "function") {
    throw new TypeError("MCP client must provide listTools() and callTool()");
  }
  const prefix = options.prefix ?? "";
  if (typeof prefix !== "string" || !/^[A-Za-z0-9_-]*$/.test(prefix)) {
    throw new TypeError("MCP prefix must contain only letters, digits, underscore, or hyphen");
  }
  const listed = await client.listTools();
  const catalog = Array.isArray(listed) ? listed : listed?.tools;
  if (!Array.isArray(catalog) || catalog.length > maxTools) {
    throw new TypeError("MCP listTools() returned an invalid tool catalog");
  }
  const tools = catalog.map((tool, index) => {
    if (!tool || typeof tool.name !== "string" || typeof tool.description !== "string") {
      throw new TypeError(`MCP tool ${index} is invalid`);
    }
    const name = `${prefix}${tool.name}`;
    return {
      name,
      description: tool.description,
      inputSchema: tool.inputSchema ?? { type: "object", properties: {} },
      async execute(input, { signal }) {
        const result = await client.callTool({ name: tool.name, arguments: input }, { signal });
        const text = resultText(result);
        if (result?.isError) throw new Error(text || `MCP tool ${tool.name} failed`);
        return text;
      },
    };
  });

  const instructions = [];
  for (const uri of options.resources ?? []) {
    if (typeof client.readResource !== "function") throw new TypeError("MCP client does not provide readResource()");
    const result = await client.readResource({ uri });
    appendInstruction(instructions, "mcp_resource", contentText(result?.contents ?? result?.content));
  }
  for (const prompt of options.prompts ?? []) {
    if (typeof client.getPrompt !== "function") throw new TypeError("MCP client does not provide getPrompt()");
    const request = typeof prompt === "string" ? { name: prompt } : prompt;
    const result = await client.getPrompt(request);
    appendInstruction(
      instructions,
      "mcp_prompt",
      (result?.messages ?? []).map((message) => contentText(message.content)).filter(Boolean).join("\n"),
    );
  }
  const instructionText = instructions.join("\n\n");
  if (new TextEncoder().encode(instructionText).length > maxInstructionsBytes) {
    throw new RangeError(`MCP instructions exceed the ${maxInstructionsBytes} byte libfx limit`);
  }

  let closed = false;
  return {
    tools,
    instructions: instructionText,
    async close() {
      if (closed) return;
      closed = true;
      await client.close?.();
    },
  };
}
