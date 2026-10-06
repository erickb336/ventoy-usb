// Checks the README's graphics. Run `node scripts/check-graphics.mjs`; it exits 1 and lists each problem.
// 1. Each SVG in docs/assets is exactly what scripts/graphics.mjs draws, so nobody edits or adds an SVG by hand.
// 2. Each text stays 7 px or more on a phone, where GitHub shows a graphic 324 px wide (the README column on a 390 px screen).
// 3. The README shows each graphic in the reader's theme: a link to the light SVG, then <picture> with the dark <source>
//    and an <img> with alt text, each on its own line. On the same line as <picture>, GitHub drops the dark version.
// 4. Each file that the README names in docs/assets exists.
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { files } from "./graphics.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const ASSETS = join(ROOT, "docs/assets");
const PHONE = 324;
const problems = [];

const drawn = new Map(files());
for (const [f, svg] of drawn) {
  const file = join(ASSETS, f);
  if (!existsSync(file) || readFileSync(file, "utf8") !== svg) problems.push(`docs/assets/${f}: out of date; run node scripts/graphics.mjs`);
  const width = +/viewBox="0 0 ([\d.]+)/.exec(svg)[1];
  const small = Math.min(...[...svg.matchAll(/font-size="([\d.]+)"/g)].map((m) => +m[1]));
  if ((small * PHONE) / width < 7) problems.push(`docs/assets/${f}: a ${small} px text is ${((small * PHONE) / width).toFixed(1)} px on a phone; make it ${Math.ceil((7 * width) / PHONE)} px or more`);
}
if (existsSync(ASSETS)) {
  for (const f of readdirSync(ASSETS).filter((f) => f.endsWith(".svg") && !drawn.has(f))) problems.push(`docs/assets/${f}: scripts/graphics.mjs does not draw it; draw it there, or delete it`);
}

const readme = readFileSync(join(ROOT, "README.md"), "utf8");
for (const name of new Set([...drawn.keys()].map((f) => f.replace(/-(light|dark)\.svg$/, "")))) {
  const svg = (theme) => `docs/assets/${name}-${theme}\\.svg`;
  const shown = new RegExp(`<a href="${svg("light")}">\\n<picture>\\n\\s*<source media="\\(prefers-color-scheme: dark\\)" srcset="${svg("dark")}">\\n\\s*<img alt="[^"]{20,}" src="${svg("light")}" width="100%">\\n</picture>\\n</a>\\n`);
  if (!shown.test(readme)) problems.push(`README.md: show ${name} as <a href="docs/assets/${name}-light.svg">, then <picture> with its dark <source> and an <img> with alt text and width="100%", each on its own line`);
}
for (const [, ref] of readme.matchAll(/(docs\/assets\/[\w.-]+)/g)) {
  if (!existsSync(join(ROOT, ref))) problems.push(`README.md: ${ref} does not exist`);
}
const pictures = (readme.match(/<picture>/g) ?? []).length;

if (problems.length) {
  console.error(problems.join("\n"));
  process.exit(1);
}
console.log(`graphics OK: ${drawn.size} SVG files match scripts/graphics.mjs; ${pictures} pictures in README.md`);
