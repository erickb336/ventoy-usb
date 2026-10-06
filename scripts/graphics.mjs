// Draws the README's graphics as SVG, each in a light and a dark version (docs/assets/<name>-light.svg, -dark.svg).
// The README shows the version that matches the reader's GitHub theme. Run `node scripts/graphics.mjs` after a change
// here, then `node scripts/check-graphics.mjs`. No dependencies: Node 20 or later only.
//
// The look: a circuit board. Every graphic sits on a board with a dot grid and faint traces, and the main shapes are a
// generic USB stick, ISO discs and computers. Teal traces carry the flow, an amber LED marks the USB, and red marks a
// step that erases or fails. Original shapes only: no logos or trademarks of any product, company or Linux distribution;
// the graphics name each system in plain text.
//
// Each text is 7 px or more on a phone, where a graphic is 324 px wide: check-graphics.mjs checks it. So the smallest
// text is SMALL (24) in a graphic 1100 wide, and 28 in the hero, which is 1280 wide.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "../docs/assets");

/** The two themes. Light is a pale green board with dark teal traces; dark is a night-blue board with bright teal. */
const THEMES = {
  light: { dark: false, bg: "#F2F7F6", dot: "#0F766E", dotOp: 0.13, traceOp: 0.16, tile: "#FFFFFF", panel: "#E5EFED", ink: "#0B1F1C", muted: "#46625C", line: "#8DB0A8", go: "#0F766E", led: "#D97706", bad: "#C2362B", ok: "#15803D", border: "#D0E0DC", glowOp: 0.22, stick: "#0F766E", stickInk: "#FFFFFF", metal: "#C9D3D1", disc: "#E4ECEA", hub: "#F2F7F6" },
  dark: { dark: true, bg: "#0A1316", dot: "#2DD4BF", dotOp: 0.1, traceOp: 0.14, tile: "#111D20", panel: "#0E191C", ink: "#E6F4F1", muted: "#9DB9B3", line: "#3D5A54", go: "#2DD4BF", led: "#FBBF24", bad: "#F87171", ok: "#4ADE80", border: "#1D302C", glowOp: 0.45, stick: "#115E59", stickInk: "#E6FFFA", metal: "#5B6B69", disc: "#1B2B2E", hub: "#0A1316" },
};
const SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Inter, Helvetica, Arial, sans-serif";
const MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
const SMALL = 24;

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const attrs = (o) => Object.entries(o).filter(([, v]) => v !== undefined && v !== null).map(([k, v]) => `${k}="${v}"`).join(" ");
const f1 = (n) => +(+n).toFixed(1);
/** A seeded random generator, so that each run draws the same file. */
const seeded = (seed) => () => ((seed = (seed * 16807) % 2147483647) - 1) / 2147483646;

/** Text, one tspan per line. */
function text(x, y, lines, { size = 16, weight = 400, fill, anchor = "start", mono = false, lh = 1.35, opacity, ls } = {}) {
  const ts = [].concat(lines).map((l, i) => `<tspan x="${x}" dy="${i === 0 ? 0 : f1(size * lh)}">${esc(l)}</tspan>`).join("");
  return `<text ${attrs({ x, y, "font-family": mono ? MONO : SANS, "font-size": size, "font-weight": weight, fill, "text-anchor": anchor, opacity, "letter-spacing": ls })}>${ts}</text>`;
}
const rect = (x, y, w, h, o = {}) => `<rect ${attrs({ x: f1(x), y: f1(y), width: f1(w), height: f1(h), rx: o.rx ?? 10, fill: o.fill ?? "none", stroke: o.stroke, "stroke-width": o.sw, "stroke-dasharray": o.dash, opacity: o.opacity, filter: o.filter })}/>`;
const path = (d, o = {}) => `<path ${attrs({ d, fill: o.fill ?? "none", stroke: o.stroke, "stroke-width": o.sw ?? 2, "stroke-dasharray": o.dash, "stroke-linecap": "round", "stroke-linejoin": "round", opacity: o.opacity })}/>`;
const circle = (cx, cy, r, o = {}) => `<circle ${attrs({ cx: f1(cx), cy: f1(cy), r: f1(r), fill: o.fill ?? "none", stroke: o.stroke, "stroke-width": o.sw, opacity: o.opacity, filter: o.filter })}/>`;

/** The arrowheads: go (the main flow), bad (an error path), muted. */
const markers = (id, t) => [["go", t.go], ["bad", t.bad], ["muted", t.line]].map(([name, color]) => `<marker id="${id}-${name}" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="12" markerHeight="12" markerUnits="userSpaceOnUse" orient="auto-start-reverse"><path d="M0 0 L12 6 L0 12 L3 6 z" fill="${color}"/></marker>`).join("\n");
/** A line with an arrowhead at its end. */
const flow = (id, d, color, marker, o = {}) => `<path d="${d}" fill="none" stroke="${color}" stroke-width="${o.sw ?? 3}"${o.dash ? ` stroke-dasharray="${o.dash}"` : ""} stroke-linecap="round" stroke-linejoin="round"${marker ? ` marker-end="url(#${id}-${marker})"` : ""}/>`;

/** The board: a dot grid and faint traces that end in round pads. Draw it first, so every label sits on top. */
function board(t, id, W, H, seed) {
  const r = seeded(seed), traces = [];
  for (let i = 0; i < Math.round((W * H) / 52000); i++) {
    let x = Math.round((r() * W) / 20) * 20, y = Math.round((r() * H) / 20) * 20;
    let d = `M${x} ${y}`;
    const pads = [[x, y]];
    for (let k = 0; k < 3; k++) {
      const len = 40 + Math.round(r() * 6) * 20, dir = r();
      if (dir < 0.5) x += r() < 0.5 ? len : -len;
      else if (dir < 0.75) { x += len / 2; y += r() < 0.5 ? len / 2 : -len / 2; }
      else y += r() < 0.5 ? len : -len;
      d += ` L${x} ${y}`;
    }
    pads.push([x, y]);
    traces.push(path(d, { stroke: t.dot, sw: 2.5, opacity: t.traceOp }), ...pads.map(([px, py]) => circle(px, py, 5, { stroke: t.dot, sw: 2.5, opacity: t.traceOp })));
  }
  return [`<rect width="${W}" height="${H}" fill="url(#${id}-dots)"/>`, ...traces].join("\n");
}

/** A whole graphic: the board, the body and a rounded frame, with a full aria-label. */
function svg(t, id, W, H, seed, body, label) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="${esc(label)}">
<style>.blink{animation:blink 2.4s ease-in-out infinite}@keyframes blink{50%{opacity:.35}}@media (prefers-reduced-motion:reduce){.blink{animation:none}}</style>
<defs>
<pattern id="${id}-dots" width="20" height="20" patternUnits="userSpaceOnUse"><circle cx="10" cy="10" r="1.4" fill="${t.dot}" opacity="${t.dotOp}"/></pattern>
<filter id="${id}-glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4"/></filter>
<clipPath id="${id}-frame"><rect width="${W}" height="${H}" rx="24"/></clipPath>
${markers(id, t)}
</defs>
<g clip-path="url(#${id}-frame)">
<rect width="${W}" height="${H}" fill="${t.bg}"/>
${board(t, id, W, H, seed)}
${body}
</g>
<rect x="0.75" y="0.75" width="${W - 1.5}" height="${H - 1.5}" rx="23.25" fill="none" stroke="${t.border}" stroke-width="1.5"/>
</svg>
`;
}

/* ---- The shapes ---------------------------------------------------------------------------------------------- */

/** A generic USB stick, plug to the left. (x, y) is the top-left of its body; the plug sticks out to the left. */
function stick(t, id, x, y, w, h, label, labelSize) {
  const px = x - h * 0.55, py = y + h * 0.2, ph = h * 0.6;
  return [
    rect(px, py, h * 0.6, ph, { rx: 4, fill: t.metal, stroke: t.line, sw: 1.5 }),
    rect(px + h * 0.12, py + ph * 0.22, h * 0.14, ph * 0.18, { rx: 1, fill: t.bg }),
    rect(px + h * 0.12, py + ph * 0.6, h * 0.14, ph * 0.18, { rx: 1, fill: t.bg }),
    rect(x, y, w, h, { rx: h * 0.28, fill: t.stick }),
    rect(x + 6, y + 6, w - 12, h * 0.3, { rx: h * 0.2, fill: "#FFFFFF", opacity: 0.08 }),
    circle(x + w - h * 0.3, y + h / 2, h * 0.16, { fill: t.led, opacity: 0.8, filter: `url(#${id}-glow)` }),
    `<g class="blink">${circle(x + w - h * 0.3, y + h / 2, h * 0.09, { fill: t.led })}</g>`,
    label ? text(f1(x + (w - h * 0.5) / 2 + 4), f1(y + h / 2 + labelSize * 0.36), label, { size: labelSize, weight: 800, fill: t.stickInk, anchor: "middle", ls: 1.5 }) : "",
  ].join("");
}

/** An ISO disc: a silver ring, a hub and a short amber shine. */
function disc(t, cx, cy, r) {
  return [
    circle(cx, cy, r, { fill: t.disc, stroke: t.line, sw: 2 }),
    circle(cx, cy, r * 0.66, { stroke: t.line, sw: 1, opacity: 0.6 }),
    path(`M${f1(cx - r * 0.8)} ${f1(cy - r * 0.3)} A${f1(r * 0.85)} ${f1(r * 0.85)} 0 0 1 ${f1(cx - r * 0.25)} ${f1(cy - r * 0.8)}`, { stroke: t.led, sw: f1(r * 0.1), opacity: 0.7 }),
    circle(cx, cy, r * 0.24, { fill: t.hub, stroke: t.line, sw: 1.5 }),
  ].join("");
}

/** A desktop monitor, w wide, centred on cx with its top at y. mark: "power", "check" or none. */
function monitor(t, cx, y, w, mark) {
  const h = w * 0.62, x = cx - w / 2;
  const sign = mark === "check" ? path(`M${f1(cx - h * 0.16)} ${f1(y + h * 0.5)} L${f1(cx - h * 0.04)} ${f1(y + h * 0.62)} L${f1(cx + h * 0.2)} ${f1(y + h * 0.36)}`, { stroke: t.ok, sw: f1(w * 0.05) })
    : mark === "power" ? path(`M${f1(cx - h * 0.13)} ${f1(y + h * 0.38)} A${f1(h * 0.18)} ${f1(h * 0.18)} 0 1 0 ${f1(cx + h * 0.13)} ${f1(y + h * 0.38)} M${cx} ${f1(y + h * 0.28)} L${cx} ${f1(y + h * 0.5)}`, { stroke: t.go, sw: f1(w * 0.045) }) : "";
  return [
    rect(x, y, w, h, { rx: 8, fill: t.tile, stroke: t.ink, sw: 3 }),
    rect(x + 8, y + 8, w - 16, h - 16, { rx: 4, fill: t.panel }),
    sign,
    path(`M${f1(cx - w * 0.08)} ${f1(y + h)} L${f1(cx - w * 0.11)} ${f1(y + h + w * 0.14)} L${f1(cx + w * 0.11)} ${f1(y + h + w * 0.14)} L${f1(cx + w * 0.08)} ${f1(y + h)}`, { fill: t.ink, stroke: t.ink, sw: 2 }),
    rect(cx - w * 0.22, y + h + w * 0.13, w * 0.44, w * 0.05, { rx: 3, fill: t.ink }),
  ].join("");
}

/** A laptop, w wide at its base, centred on cx with the top of its screen at y. */
function laptop(t, cx, y, w) {
  const sw = w * 0.78, sh = sw * 0.62, x = cx - sw / 2;
  return [
    rect(x, y, sw, sh, { rx: 7, fill: t.tile, stroke: t.ink, sw: 3 }),
    rect(x + 7, y + 7, sw - 14, sh - 14, { rx: 3, fill: t.panel }),
    path(`M${f1(cx - w / 2)} ${f1(y + sh + w * 0.1)} L${f1(x - 2)} ${f1(y + sh + 2)} L${f1(x + sw + 2)} ${f1(y + sh + 2)} L${f1(cx + w / 2)} ${f1(y + sh + w * 0.1)} Z`, { fill: t.ink, stroke: t.ink, sw: 2 }),
  ].join("");
}

/** A number in a circle. */
const badge = (t, cx, cy, r, n, color) => circle(cx, cy, r, { fill: color }) + text(cx, f1(cy + SMALL * 0.36), String(n), { size: SMALL, weight: 800, fill: t.bg, anchor: "middle" });

/** A label in capitals, the heading inside a graphic. */
const heading = (t, x, y, s) => text(x, y, s, { size: SMALL, weight: 800, fill: t.go, ls: 2 });

/** A box with an optional glow. kind: go (teal edge), bad (red edge), ok (green edge), plain. */
function box(t, id, x, y, w, h, kind = "plain") {
  const color = { go: t.go, bad: t.bad, ok: t.ok }[kind] ?? t.line;
  return (kind === "plain" ? "" : rect(x, y, w, h, { rx: 10, stroke: color, sw: 6, opacity: t.glowOp, filter: `url(#${id}-glow)` })) +
    rect(x, y, w, h, { rx: 10, fill: t.tile, stroke: color, sw: kind === "plain" ? 1.5 : 2.5 });
}

/* ---- The graphics -------------------------------------------------------------------------------------------- */

/** The hero: one USB stick, many ISO discs, prepared from any of three computers, then booted on the target PC. */
function hero(t, id) {
  const W = 1280, H = 740, S = 28;
  const out = [];
  out.push(text(64, 112, "ventoy", { size: 76, weight: 800, fill: t.ink, mono: true }), text(64 + 6 * 76 * 0.6, 112, "-usb", { size: 76, weight: 800, fill: t.go, mono: true }));
  out.push(text(66, 172, "One USB stick. Many ISO files. Pick one when the PC starts.", { size: 34, weight: 700, fill: t.ink }));
  out.push(text(66, 220, "Prepare the USB from Windows, macOS or Linux.", { size: S, fill: t.muted }));
  // The three computers that can prepare the USB.
  const rows = [["Windows", ".\\ventoy.ps1", "monitor"], ["macOS", "./ventoy.sh", "laptop"], ["Linux", "./ventoy.sh", "monitor"]];
  rows.forEach(([name, cmd, kind], i) => {
    const y = 290 + i * 128;
    out.push(box(t, id, 64, y, 360, 108));
    out.push(kind === "laptop" ? laptop(t, 124, y + 30, 92) : monitor(t, 124, y + 22, 78));
    out.push(text(190, y + 46, name, { size: 30, weight: 800, fill: t.ink }), text(190, y + 84, cmd, { size: S, fill: t.go, mono: true }));
    out.push(flow(id, `M424 ${y + 54} L 456 ${y + 54} L 456 ${560} L 486 560`, t.go, i === 1 ? "go" : null));
  });
  // The ISO discs that go onto the stick.
  const discs = [["Windows 11", 620], ["Linux", 770], ["Rescue", 920]];
  for (const [label, cx] of discs) {
    out.push(disc(t, cx, 350, 50));
    out.push(text(cx, 438, label, { size: S, weight: 700, fill: t.ink, anchor: "middle" }));
    out.push(flow(id, `M${cx} 452 L ${cx} 512`, t.go, "go", { dash: "7 7" }));
  }
  out.push(text(1000, 360, "+ more", { size: S, weight: 700, fill: t.muted }));
  // The stick.
  out.push(stick(t, id, 530, 520, 470, 84, "MULTIBOOT USB", 30));
  // The target PC.
  out.push(flow(id, `M1004 562 L 1088 562`, t.go, "go"));
  out.push(monitor(t, 1166, 470, 120, "power"));
  out.push(text(1166, 640, "Target PC", { size: 30, weight: 800, fill: t.ink, anchor: "middle" }));
  out.push(text(1166, 676, ["picks an ISO", "at boot"], { size: S, fill: t.muted, anchor: "middle", lh: 1.2 }));
  return svg(t, id, W, H, 11, out.join("\n"), "ventoy-usb: one USB stick, many ISO files; pick one when the PC starts. Prepare the USB from Windows with .\\ventoy.ps1, or from macOS or Linux with ./ventoy.sh. ISO files such as Windows 11, a Linux system or a rescue disk go onto one multiboot USB. Then the target PC starts from the USB, and you pick an ISO at boot.");
}

/** Pick your computer: the entry command for each computer, then option 1 or option 2. Option 1 continues to option 2. */
function pick(t, id) {
  const W = 1100, rowH = 150, y0 = 104;
  const rows = [
    ["Windows", "10 or 11", "monitor", ".\\ventoy.ps1", "PowerShell as admin", "1  Create a new USB (erases it)", "2  Add an ISO, SHA-256 checked"],
    ["macOS", "13.5 or later", "laptop", "./ventoy.sh", "Terminal", "1  Mactoy creates it (erases USB)", "2  Add an ISO, SHA-256 checked"],
    ["Linux", "uses sudo", "monitor", "./ventoy.sh", "Terminal", "1  Create a new USB (erases it)", "2  Copy ISOs from a folder"],
  ];
  const out = [heading(t, 36, 62, "PICK YOUR COMPUTER")];
  rows.forEach(([name, sub, kind, cmd, where, o1, o2], i) => {
    const y = y0 + i * (rowH + 22), mid = y + rowH / 2;
    out.push(box(t, id, 36, y, 210, rowH));
    out.push(kind === "laptop" ? laptop(t, 141, y + 16, 70) : monitor(t, 141, y + 12, 58));
    out.push(text(141, y + 100, name, { size: 28, weight: 800, fill: t.ink, anchor: "middle" }), text(141, y + 132, sub, { size: SMALL, fill: t.muted, anchor: "middle" }));
    out.push(flow(id, `M250 ${mid} L 282 ${mid}`, t.go, "go"));
    out.push(box(t, id, 290, y + 30, 262, 90, "go"));
    out.push(text(421, y + 68, cmd, { size: 26, weight: 700, fill: t.go, anchor: "middle", mono: true }), text(421, y + 102, where, { size: SMALL, fill: t.muted, anchor: "middle" }));
    const py1 = y + 8, py2 = y + rowH - 64;
    out.push(flow(id, `M556 ${mid} L 574 ${mid} L 574 ${py1 + 28} L 596 ${py1 + 28}`, t.go, "go"), flow(id, `M574 ${mid} L 574 ${py2 + 28} L 596 ${py2 + 28}`, t.go, "go"));
    out.push(box(t, id, 600, py1, 418, 56, "bad"), text(622, py1 + 37, o1, { size: SMALL, weight: 700, fill: t.ink }));
    out.push(box(t, id, 600, py2, 418, 56, "ok"), text(622, py2 + 37, o2, { size: SMALL, weight: 700, fill: t.ink }));
    // Option 1 continues to option 2 when it finishes.
    out.push(flow(id, `M1022 ${py1 + 28} L 1050 ${py1 + 28} L 1050 ${py2 + 28} L 1026 ${py2 + 28}`, t.line, "muted", { dash: "6 6" }));
  });
  const fy = y0 + 3 * (rowH + 22) + 14;
  out.push(text(36, fy, ["Red: this option erases the USB. Dashed: option 1 continues", "with option 2 when it finishes."], { size: SMALL, fill: t.muted, lh: 1.35 }));
  return svg(t, id, W, fy + 64, 23, out.join("\n"), "Pick your computer. Windows 10 or 11: run .\\ventoy.ps1 in PowerShell as administrator. Option 1 creates a new USB and erases it; option 2 adds an ISO with a SHA-256 check. macOS 13.5 or later: run ./ventoy.sh in Terminal. Option 1 hands over to the Mactoy app, which creates the USB and erases it; option 2 adds an ISO with a SHA-256 check. Linux, which uses sudo: run ./ventoy.sh in Terminal. Option 1 creates a new USB and erases it; option 2 copies ISOs from a folder. On every computer, option 1 continues with option 2 when it finishes.");
}

/** The journey: prepare the USB and add the ISO on this computer, then boot and install on the target PC. */
function journey(t, id) {
  const W = 1100, tw = 230, gap = 34, ty = 132, th = 330;
  const steps = [
    ["Prepare the USB", ["Install Ventoy", "once. This erases", "the USB."], "stick"],
    ["Add the ISO", ["Copy the Windows 11", "ISO to the USB.", "Windows and macOS", "check its SHA-256."], "disc"],
    ["Boot the PC", ["One-time boot menu:", "UEFI USB entry. Pick", "the ISO in Ventoy."], "power"],
    ["Install", ["Pick the internal", "disk, never the USB.", "Then start from it."], "check"],
  ];
  const out = [heading(t, 36, 62, "THE WHOLE JOURNEY · WINDOWS 11 EXAMPLE")];
  // The two places.
  out.push(rect(28, 86, 2 * tw + gap + 16, 392, { rx: 14, stroke: t.line, sw: 1.5, dash: "8 8" }), text(44, 116, "ON THIS COMPUTER", { size: SMALL, weight: 700, fill: t.muted, ls: 1.5 }));
  const x3 = 36 + 2 * (tw + gap);
  out.push(rect(x3 - 8, 86, 2 * tw + gap + 16, 392, { rx: 14, stroke: t.line, sw: 1.5, dash: "8 8" }), text(x3 + 8, 116, "ON THE TARGET PC", { size: SMALL, weight: 700, fill: t.muted, ls: 1.5 }));
  steps.forEach(([title, sub, icon], i) => {
    const x = 36 + i * (tw + gap), cx = x + tw / 2;
    out.push(box(t, id, x, ty, tw, th, i === 0 ? "bad" : "plain"));
    out.push(badge(t, x + 32, ty + 32, 21, i + 1, i === 0 ? t.bad : t.go));
    if (icon === "stick") out.push(stick(t, id, cx - 40, ty + 50, 110, 44, "", 0));
    if (icon === "disc") out.push(disc(t, cx, ty + 78, 38));
    if (icon === "power" || icon === "check") out.push(monitor(t, cx, ty + 40, 86, icon));
    out.push(text(cx, ty + 160, title, { size: 26, weight: 800, fill: t.ink, anchor: "middle" }));
    out.push(text(cx, ty + 198, sub, { size: SMALL, fill: t.muted, anchor: "middle", lh: 1.3 }));
    if (i < 3) out.push(flow(id, `M${x + tw + 4} ${ty + th / 2} L ${x + tw + gap - 4} ${ty + th / 2}`, t.go, "go"));
  });
  out.push(text(36, 524, ["Between steps 2 and 3, eject the USB and move it to the target PC.", "Steps 1 and 2 never change the target PC or its disks."], { size: SMALL, fill: t.muted, lh: 1.35 }));
  return svg(t, id, W, 590, 37, out.join("\n"), "The whole journey, with Windows 11 as the example. On this computer: 1, prepare the USB: install Ventoy once, which erases the USB. 2, add the ISO: copy the Windows 11 ISO to the USB; on Windows and macOS, the utility checks its SHA-256. Then eject the USB and move it to the target PC. On the target PC: 3, boot the PC: open the one-time boot menu, choose the UEFI USB entry, and pick the ISO in Ventoy. 4, install: in Windows Setup, pick the internal disk, never the USB, then start from that disk. Steps 1 and 2 never change the target PC or its disks.");
}

/** The verified copy: the steps that Windows and macOS share, the macOS remount, and the clean-up after an error. */
function copy(t, id) {
  const W = 1100, x = 36, w = 700, h = 58, gap = 18, y0 = 96;
  const steps = [
    ["Check: same USB, free space, FAT32 limit, name not used", "plain"],
    ["Write to a hidden temp file (.ventoy-copy-…)", "plain"],
    ["Copy, with %, GiB, MiB/s and time left", "plain"],
    ["Flush the data to the USB", "plain"],
    ["macOS only: unmount, mount again, check the USB", "go"],
    ["Read the SHA-256 of the source and of the copy", "plain"],
    ["Same? Rename the temp file. Never overwrite a file.", "plain"],
  ];
  const out = [heading(t, 36, 62, "THE VERIFIED COPY · WINDOWS AND MACOS")];
  const busX = w + x + 52;
  steps.forEach(([label, kind], i) => {
    const y = y0 + i * (h + gap);
    out.push(box(t, id, x, y, w, h, kind === "go" ? "go" : "plain"));
    out.push(badge(t, x + 32, y + h / 2, 20, i + 1, t.go));
    out.push(text(x + 64, y + h / 2 + 8, label, { size: SMALL, weight: i === 4 ? 700 : 400, fill: t.ink }));
    if (i < steps.length - 1) out.push(flow(id, `M${x + 32} ${y + h + 2} L ${x + 32} ${y + h + gap - 2}`, t.go, "go", { sw: 2.5 }));
    if (i >= 1) out.push(flow(id, `M${x + w + 4} ${y + h / 2} L ${busX} ${y + h / 2}`, t.bad, null, { sw: 2, dash: "5 6" }));
  });
  const yEnd = y0 + steps.length * (h + gap);
  out.push(flow(id, `M${x + 32} ${yEnd - gap + 2} L ${x + 32} ${yEnd + 8}`, t.go, "go", { sw: 2.5 }));
  out.push(box(t, id, x, yEnd + 12, w, h, "ok"), text(x + w / 2, yEnd + 12 + h / 2 + 8, "ISO copied and SHA-256 verified.", { size: SMALL, weight: 800, fill: t.ink, anchor: "middle" }));
  // The error path.
  const by0 = y0 + h + gap + h / 2, by1 = y0 + 6 * (h + gap) + h / 2;
  out.push(path(`M${busX} ${by0} L ${busX} ${by1}`, { stroke: t.bad, sw: 2, dash: "5 6" }));
  const bx = busX + 18, bw = W - 36 - bx, bTop = by0 + 40, bh = 300;
  out.push(flow(id, `M${busX} ${bTop + bh / 2} L ${bx - 4} ${bTop + bh / 2}`, t.bad, "bad", { sw: 2.5 }));
  out.push(box(t, id, bx, bTop, bw, bh, "bad"));
  out.push(text(bx + bw / 2, bTop + 48, ["Any error,", "a different", "SHA-256 or", "Ctrl+C"], { size: SMALL, weight: 800, fill: t.bad, anchor: "middle", lh: 1.3 }));
  out.push(text(bx + bw / 2, bTop + 188, ["The utility", "removes the", "temp file", "and stops."], { size: SMALL, fill: t.ink, anchor: "middle", lh: 1.3 }));
  return svg(t, id, W, yEnd + h + 46, 53, out.join("\n"), "The verified copy, on Windows and macOS. 1, check: the same USB, enough free space, the FAT32 file size limit, and no file with the same name. 2, write to a hidden temp file named .ventoy-copy-something. 3, copy, with the percent, GiB copied, MiB per second and time left. 4, flush the data to the USB. 5, on macOS only: unmount the USB, mount it again, and check that it is the same USB. 6, read the SHA-256 of the source and of the copy. 7, if they are the same, rename the temp file to the ISO name; it never overwrites a file. Then: ISO copied and SHA-256 verified. After step 2, any error, a different SHA-256 or Ctrl+C makes the utility remove the temp file and stop.");
}

/** A tip: a USB stick in a round badge on the left, and the tip in a framed card to the right. */
const tip = (lines, label, seed) => (t, id) => {
  const W = 1100, size = 24, lh = 1.4, H = 120 + lines.length * size * lh + 30;
  const sx = 210, sy = 30, sw = W - 36 - sx, sh = H - 60;
  const body = [
    circle(110, H / 2, 82, { fill: t.led, opacity: t.glowOp, filter: `url(#${id}-glow)` }),
    circle(110, H / 2, 74, { fill: t.tile, stroke: t.led, sw: 3 }),
    stick(t, id, 82, H / 2 - 22, 80, 44, "", 0),
    box(t, id, sx, sy, sw, sh, "plain"),
    rect(sx, sy, 8, sh, { rx: 4, fill: t.led }),
    text(sx + 40, sy + 52, "TIP", { size: SMALL, weight: 800, fill: t.led, ls: 2 }),
    text(sx + 40, sy + 94, lines, { size, weight: 600, fill: t.ink, lh }),
  ].join("\n");
  return svg(t, id, W, Math.round(H), seed, body, label);
};

const GRAPHICS = {
  hero, pick, journey, copy,
  "tip-yes": tip(["Type YES only after you check the disk name and size.", "At “Select USB by list number”, type the number", "in [ ], not the disk number or the drive letter."], "Tip: type YES only after you check the disk name and size. At Select USB by list number, type the number in square brackets, not the disk number or the drive letter.", 61),
  "tip-mactoy": tip(["Check Mactoy before you give it Full Disk Access:", "the .dmg must match its .sha256 file, and", "spctl -a -vv must show “Notarized Developer ID”."], "Tip: check Mactoy before you give it Full Disk Access. The SHA-256 of the .dmg file must match its .sha256 file, and spctl -a -vv must show source=Notarized Developer ID.", 67),
};

/** Every graphic in both themes, as [file name, SVG]. The ids in a file start with its own name and theme, so that
 *  two graphics on one page never share an id. */
export const files = () => Object.entries(GRAPHICS).flatMap(([name, draw]) => Object.entries(THEMES).map(([theme, t]) => [`${name}-${theme}.svg`, draw(t, `${name}-${theme[0]}`)]));

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  mkdirSync(OUT, { recursive: true });
  const all = files();
  for (const [file, content] of all) writeFileSync(join(OUT, file), content);
  console.log(`drew ${all.length} files in docs/assets`);
}
