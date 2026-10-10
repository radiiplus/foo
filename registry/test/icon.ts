import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { test } from "node:test";

import { Icon } from "../ui/src/components/icon.ts";

test("package SVG is isolated in an image element", () => {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0"/></svg>';
  const html = renderToStaticMarkup(createElement(Icon, { svg, children: "fallback" }));
  assert.match(html, /^<img /);
  assert.match(html, /src="data:image\/svg\+xml;charset=utf-8,/);
  assert.doesNotMatch(html, /<svg|<path/);
  assert.equal(renderToStaticMarkup(createElement(Icon, { svg: "<script>alert(1)</script>", children: "fallback" })), "fallback");
});
