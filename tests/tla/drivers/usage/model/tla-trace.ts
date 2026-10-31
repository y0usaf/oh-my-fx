
export type Value = number | boolean | string | null | { [key: string]: Value };
export type State = Record<string, Value>;

const TOKEN = /\s*(\|->|:>|@@|\(|\)|\[|\]|,|-?\d+|[A-Za-z_][A-Za-z0-9_]*)/y;

function tokenize(text: string): string[] {
  const tokens: string[] = [];
  TOKEN.lastIndex = 0;
  while (TOKEN.lastIndex < text.length) {
    if (/^\s*$/.test(text.slice(TOKEN.lastIndex))) break;
    const start = TOKEN.lastIndex;
    const match = TOKEN.exec(text);
    if (!match) throw new Error(`unexpected TLA+ text at ${start}: ${text.slice(start, start + 30)}`);
    tokens.push(match[1]);
  }
  return tokens;
}

function parseValue(tokens: string[]): Value {
  let at = 0;
  const next = () => {
    const token = tokens[at++];
    if (token === undefined) throw new Error("TLA+ value ended early");
    return token;
  };
  const expect = (want: string) => {
    const got = next();
    if (got !== want) throw new Error(`expected ${want}, found ${got}`);
  };
  const atom = (token: string): Value => {
    if (/^-?\d+$/.test(token)) return Number(token);
    if (token === "TRUE") return true;
    if (token === "FALSE") return false;
    if (token === "None") return null;
    if (/^[A-Za-z_]/.test(token)) return token;
    throw new Error(`unexpected token ${token}`);
  };
  const value = (): Value => {
    const token = next();
    if (token === "[") {
      const record: { [key: string]: Value } = {};
      for (;;) {
        const key = next();
        expect("|->");
        record[key] = value();
        const sep = next();
        if (sep === "]") return record;
        if (sep !== ",") throw new Error(`expected , or ], found ${sep}`);
      }
    }
    if (token === "(") {
      if (tokens[at + 1] !== ":>") {
        const inner = value();
        expect(")");
        return inner;
      }
      const fn: { [key: string]: Value } = {};
      for (;;) {
        const key = String(atom(next()));
        expect(":>");
        fn[key] = value();
        const sep = next();
        if (sep === ")") return fn;
        if (sep !== "@@") throw new Error(`expected @@ or ), found ${sep}`);
      }
    }
    return atom(token);
  };
  const result = value();
  if (at !== tokens.length) throw new Error(`trailing TLA+ tokens: ${tokens.slice(at).join(" ")}`);
  return result;
}

/** The states of one TLC behavior file, in order. */
export function parseBehavior(text: string): State[] {
  const chunks = text.split(/^STATE_\d+ ==\s*$/m).slice(1);
  return chunks.map((chunk) => {
    const body = chunk.split(/^={4,}/m)[0];
    const state: State = {};
    const assignments = [...body.matchAll(/^\/\\ (\w+) = /gm)];
    assignments.forEach((match, index) => {
      const start = match.index! + match[0].length;
      const end = index + 1 < assignments.length ? assignments[index + 1].index! : body.length;
      state[match[1]] = parseValue(tokenize(body.slice(start, end)));
    });
    return state;
  });
}
