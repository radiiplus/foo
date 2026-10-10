import { SaxesParser } from "saxes";

const namespace = "http://www.w3.org/2000/svg";
const elements = new Set(["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]);
const paint = new Set(["fill", "stroke", "color"]);
const numbers = new Set(["x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "width", "height",
  "stroke-width", "stroke-miterlimit", "stroke-dashoffset", "opacity", "fill-opacity", "stroke-opacity"]);
const choices: Record<string, Set<string>> = {
  "stroke-linecap": new Set(["butt", "round", "square"]),
  "stroke-linejoin": new Set(["miter", "round", "bevel"]),
  "fill-rule": new Set(["nonzero", "evenodd"]),
};
const number = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
const list = /^[+\-\d.eE,\s]+$/;
const path = /^[a-zA-Z+\-\d.eE,\s]+$/;
const color = /^(?:none|currentColor|transparent|#[0-9a-fA-F]{3,8}|[a-zA-Z]+|rgba?\([\d.,%\s]+\))$/;

function escape(value: string) {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}

function valid(name: string, value: string, root: boolean) {
  if (name === "viewBox") return root && list.test(value) && value.trim().split(/[\s,]+/).length === 4 &&
    value.trim().split(/[\s,]+/).every((part) => number.test(part));
  if (name === "d") return !root && path.test(value) && /[Mm]/.test(value);
  if (name === "points" || name === "stroke-dasharray") return list.test(value) &&
    value.trim().split(/[\s,]+/).every((part) => number.test(part));
  if (paint.has(name)) return color.test(value);
  if (numbers.has(name)) return number.test(value) && Number.isFinite(Number(value));
  return choices[name]?.has(value) ?? false;
}

export function icon(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || !value.trim()) throw new TypeError("Icon must be SVG text");
  if (new TextEncoder().encode(value).length > 64 * 1024) throw new TypeError("Icon exceeds 64 KiB");

  const parser = new SaxesParser({ xmlns: false });
  const output: string[] = [];
  const stack: string[] = [];
  let roots = 0;
  let count = 0;
  const invalid = () => { throw new TypeError("Icon contains unsupported SVG content"); };
  parser.on("error", invalid);
  parser.on("doctype", invalid);
  parser.on("processinginstruction", invalid);
  parser.on("cdata", invalid);
  parser.on("text", (text) => { if (text.trim()) invalid(); });
  parser.on("opentag", (tag) => {
    const root = stack.length === 0;
    if (!elements.has(tag.name) || (root && (tag.name !== "svg" || ++roots !== 1)) ||
        ++count > 256 || stack.length >= 16) invalid();
    const attributes: string[] = [];
    if (root) {
      if (tag.attributes.xmlns !== namespace) invalid();
      attributes.push(`xmlns="${namespace}"`);
    }
    for (const [name, raw] of Object.entries(tag.attributes)) {
      if (root && name === "xmlns") continue;
      if (!valid(name, raw, root)) invalid();
      attributes.push(`${name}="${escape(raw)}"`);
    }
    output.push(`<${tag.name}${attributes.length ? ` ${attributes.join(" ")}` : ""}>`);
    stack.push(tag.name);
  });
  parser.on("closetag", (tag) => {
    if (stack.pop() !== tag.name) invalid();
    output.push(`</${tag.name}>`);
  });
  try {
    parser.write(value).close();
  } catch {
    throw new TypeError("Icon contains unsupported or malformed SVG");
  }
  if (roots !== 1 || stack.length || count < 2) throw new TypeError("Icon must contain SVG shapes");
  return output.join("");
}
