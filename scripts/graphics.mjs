// Draws the README's graphics as SVG, each in a light and a dark version (docs/assets/<name>-light.svg, -dark.svg).
// The README shows the version that matches the reader's GitHub theme. Run `node scripts/graphics.mjs` after a change
// here, then `node scripts/check-graphics.mjs`. No dependencies: Node 20 or later only.
//
// The look: a circuit board. Every graphic sits on a board with a dot grid and faint traces, and the main shapes are a
// generic USB stick, ISO discs and computers. Blue traces carry the flow, an orange LED marks the USB, and red marks
// danger: a step that erases the USB, or a failure. Original shapes only: no logos or trademarks of any product, company or Linux distribution;
// the graphics name each system in plain text.
//
// Each text is 7 px or more on a phone, where a graphic is 324 px wide, and 10 px or more in the two dense graphics
// (journey and copy): check-graphics.mjs checks it. So the smallest text is SMALL (24) in a graphic 1100 wide, 28 in the
// hero, which is 1280 wide, and 20 in journey and copy, which are columns 600 wide.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "../docs/assets");

/** The two themes. Light is a pale blue-grey board with dark blue traces; dark is a night-blue board with bright blue.
 *  Each accent has one meaning: blue (go) is the main flow, orange (led) is a tip or attention (the USB LED, the ISO disc
 *  shine), purple (iso) is the ISO files and the Mactoy hand-off, red (bad) is danger: a step that erases the USB, or a failure
 *  (an error path), and green
 *  (ok) is only the one success box. Text on a coloured fill stays 4.5:1 or more. */
const THEMES = {
  light: { dark: false, bg: "#F3F6FA", dot: "#1D4ED8", dotOp: 0.13, traceOp: 0.16, tile: "#FFFFFF", panel: "#E6EDF6", ink: "#0B1424", muted: "#475569", line: "#94A8C4", go: "#1D4ED8", led: "#B45309", iso: "#7E22CE", bad: "#C81E1E", ok: "#15803D", border: "#D3DEEC", glowOp: 0.22, stick: "#1D4ED8", stickInk: "#FFFFFF", metal: "#C9D1DC", disc: "#E5EBF3", hub: "#F3F6FA" },
  dark: { dark: true, bg: "#0A0F1A", dot: "#60A5FA", dotOp: 0.1, traceOp: 0.14, tile: "#111A2B", panel: "#0E1626", ink: "#E6EEF8", muted: "#9FB0C8", line: "#3B4E6B", go: "#60A5FA", led: "#FB923C", iso: "#C084FC", bad: "#F87171", ok: "#4ADE80", border: "#1C2A42", glowOp: 0.45, stick: "#1E40AF", stickInk: "#EFF6FF", metal: "#5B6578", disc: "#1A2436", hub: "#0A0F1A" },
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

/** An ISO disc: a silver ring, a hub and a short orange shine. */
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
  const sign = mark === "check" ? path(`M${f1(cx - h * 0.16)} ${f1(y + h * 0.5)} L${f1(cx - h * 0.04)} ${f1(y + h * 0.62)} L${f1(cx + h * 0.2)} ${f1(y + h * 0.36)}`, { stroke: t.go, sw: f1(w * 0.05) })
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
const badge = (t, cx, cy, r, n, color, size) => circle(cx, cy, r, { fill: color }) + text(cx, f1(cy + size * 0.36), String(n), { size, weight: 800, fill: t.bg, anchor: "middle" });

/** A label in capitals, the heading inside a graphic. */
const heading = (t, x, y, s) => text(x, y, s, { size: SMALL, weight: 800, fill: t.go, ls: 2 });

/** A box with an optional glow. kind: go (blue edge), bad (red edge), ok (green edge), plain. */
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
  const rows = [["Windows", "ventoy.ps1", "monitor"], ["macOS", "./ventoy.sh", "laptop"], ["Linux", "./ventoy.sh", "monitor"]];
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
  out.push(text(1000, 360, "+ more", { size: S, weight: 700, fill: t.iso }));
  // The stick.
  out.push(stick(t, id, 530, 520, 470, 84, "MULTIBOOT USB", 30));
  // The target PC.
  out.push(flow(id, `M1004 562 L 1088 562`, t.go, "go"));
  out.push(monitor(t, 1166, 470, 120, "power"));
  out.push(text(1166, 640, "Target PC", { size: 30, weight: 800, fill: t.ink, anchor: "middle" }));
  out.push(text(1166, 676, ["picks an ISO", "at boot"], { size: S, fill: t.muted, anchor: "middle", lh: 1.2 }));
  return svg(t, id, W, H, 11, out.join("\n"), "ventoy-usb: one USB stick, many ISO files; pick one when the PC starts. Prepare the USB from Windows with ventoy.ps1 in PowerShell as administrator (the full command is in step 3 of the Windows quick start), or from macOS or Linux with ./ventoy.sh. ISO files such as Windows 11, a Linux system or a rescue disk go onto one multiboot USB. Then the target PC starts from the USB, and you pick an ISO at boot.");
}

/** Pick your computer: the entry command for each computer, then option 1 or option 2. Option 1 continues to option 2. */
function pick(t, id) {
  const W = 1100, rowH = 150, y0 = 104;
  const rows = [
    ["Windows", "10 or 11", "monitor", "ventoy.ps1", "PowerShell as admin", "1  Create a new USB (erases it)", "2  Add an ISO, SHA-256 checked"],
    ["macOS", "13.5 or later", "laptop", "./ventoy.sh", "Terminal", "1  Mactoy creates it (erases USB)", "2  Add an ISO, SHA-256 checked"],
    ["Linux", "uses sudo", "monitor", "./ventoy.sh", "Terminal", "1  Create a new USB (erases it)", "2  Add ISOs, SHA-256 checked"],
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
    out.push(box(t, id, 600, py2, 418, 56, "go"), text(622, py2 + 37, o2, { size: SMALL, weight: 700, fill: t.ink }));
    // Option 1 continues to option 2 when it finishes.
    out.push(flow(id, `M1022 ${py1 + 28} L 1050 ${py1 + 28} L 1050 ${py2 + 28} L 1026 ${py2 + 28}`, t.line, "muted", { dash: "6 6" }));
  });
  const fy = y0 + 3 * (rowH + 22) + 14;
  out.push(text(36, fy, ["Red: this option erases the USB. Dashed: option 1 continues", "with option 2 when it finishes."], { size: SMALL, fill: t.muted, lh: 1.35 }));
  return svg(t, id, W, fy + 64, 23, out.join("\n"), "Pick your computer. Windows 10 or 11: run ventoy.ps1 in PowerShell as administrator, with the full command in step 3 of the Windows quick start. Option 1 creates a new USB and erases it; option 2 adds an ISO with a SHA-256 check. macOS 13.5 or later: run ./ventoy.sh in Terminal. Option 1 hands over to the Mactoy app, which creates the USB and erases it; option 2 adds an ISO with a SHA-256 check. Linux, which uses sudo: run ./ventoy.sh in Terminal. Option 1 creates a new USB and erases it; option 2 adds the ISOs of a folder, each with a SHA-256 check. On every computer, option 1 continues with option 2 when it finishes.");
}

/** The journey, in a column for a phone: prepare the USB and add the ISO on this computer, then boot and install on the
 *  target PC. Its smallest text is 20 in a graphic 600 wide: 10.8 px on a phone. */
function journey(t, id) {
  const W = 600, S = 20, x = 28, w = W - 56, ch = 150, gap = 30;
  const steps = [
    ["Prepare the USB", ["Install Ventoy once.", "This erases the USB."], "stick"],
    ["Add the ISO", ["Copy the Windows 11 ISO", "to the USB. The utility", "checks its SHA-256."], "disc"],
    ["Boot the PC", ["One-time boot menu: UEFI", "USB entry. Pick the ISO", "in Ventoy."], "power"],
    ["Install", ["Pick the internal disk,", "never the USB. Then start", "from it."], "check"],
  ];
  const out = [heading(t, x, 56, "THE WHOLE JOURNEY"), text(x, 88, "Windows 11 example", { size: S, fill: t.muted })];
  // The two places, each with two steps. Between them, the USB moves to the target PC.
  const place = (top, label, first) => {
    out.push(rect(x - 12, top, w + 24, 2 * ch + gap + 76, { rx: 14, stroke: t.line, sw: 1.5, dash: "8 8" }), text(x + 4, top + 34, label, { size: S, weight: 700, fill: t.muted, ls: 1.5 }));
    [0, 1].forEach((k) => {
      const i = first + k, [title, sub, icon] = steps[i], y = top + 52 + k * (ch + gap), cx = x + 92;
      out.push(box(t, id, x, y, w, ch, i === 0 ? "bad" : "plain"));
      out.push(badge(t, x + 30, y + 32, 19, i + 1, i === 0 ? t.bad : t.go, S));
      if (icon === "stick") out.push(stick(t, id, cx - 46, y + 70, 100, 40, "", 0));
      if (icon === "disc") out.push(disc(t, cx, y + 92, 36));
      if (icon === "power" || icon === "check") out.push(monitor(t, cx, y + 58, 80, icon));
      out.push(text(x + 164, y + 44, title, { size: 24, weight: 800, fill: t.ink }), text(x + 164, y + 80, sub, { size: S, fill: t.muted, lh: 1.3 }));
      if (k === 0) out.push(flow(id, `M${x + 30} ${y + ch + 4} L ${x + 30} ${y + ch + gap - 4}`, t.go, "go"));
    });
    return top + 2 * ch + gap + 76;
  };
  const end1 = place(112, "ON THIS COMPUTER", 0);
  out.push(flow(id, `M${x + 30} ${end1 - 18} L ${x + 30} ${end1 + 92}`, t.go, "go"), text(x + 60, end1 + 52, "Eject the USB. Move it to the target PC.", { size: S, weight: 700, fill: t.ink }));
  const end2 = place(end1 + 70 + 40, "ON THE TARGET PC", 2);
  out.push(text(x, end2 + 46, ["Steps 1 and 2 never change the target PC", "or its disks."], { size: S, fill: t.muted, lh: 1.35 }));
  return svg(t, id, W, end2 + 100, 37, out.join("\n"), "The whole journey, with Windows 11 as the example. On this computer: 1, prepare the USB: install Ventoy once, which erases the USB. 2, add the ISO: copy the Windows 11 ISO to the USB; the utility checks its SHA-256. Then eject the USB and move it to the target PC. On the target PC: 3, boot the PC: open the one-time boot menu, choose the UEFI USB entry, and pick the ISO in Ventoy. 4, install: in Windows Setup, pick the internal disk, never the USB, then start from that disk. Steps 1 and 2 never change the target PC or its disks.");
}

/** The verified copy, in a column for a phone: the steps that Windows, macOS and Linux share, the read past the cache
 *  on macOS and Linux, and the clean-up after an error. Its smallest text is 20 in a graphic 600 wide: 10.8 px on a phone. */
function copy(t, id) {
  const W = 600, S = 20, x = 28, w = 500, h = 74, gap = 18, y0 = 112, busX = x + w + 28;
  const steps = [
    ["Check: same USB, free space,", "FAT32 limit, name not used"],
    ["Write to a temp file", "named .ventoy-copy-…"],
    ["Copy, with progress"],
    ["Flush the data to the USB"],
    ["Skip the cache. macOS: unmount,", "mount again. Linux: O_DIRECT."],
    ["Read the SHA-256 of the", "source and of the copy"],
    ["Same? Rename the temp file.", "Never overwrite a file."],
  ];
  const out = [heading(t, x, 56, "THE VERIFIED COPY"), text(x, 88, "Windows, macOS and Linux", { size: S, fill: t.muted })];
  steps.forEach((lines, i) => {
    const y = y0 + i * (h + gap);
    out.push(box(t, id, x, y, w, h, i === 4 ? "go" : "plain"));
    out.push(badge(t, x + 30, y + h / 2, 18, i + 1, t.go, S));
    out.push(text(x + 62, y + h / 2 + 7 - (lines.length - 1) * 13, lines, { size: S, weight: i === 4 ? 700 : 400, fill: t.ink, lh: 1.3 }));
    if (i < steps.length - 1) out.push(flow(id, `M${x + 30} ${y + h + 2} L ${x + 30} ${y + h + gap - 2}`, t.go, "go", { sw: 2.5 }));
    // After step 2, each step can fail: a red stub to the error line on the right.
    if (i >= 1) out.push(flow(id, `M${x + w + 4} ${y + h / 2} L ${busX} ${y + h / 2}`, t.bad, null, { sw: 2, dash: "5 6" }));
  });
  const yOk = y0 + steps.length * (h + gap) + 10;
  out.push(flow(id, `M${x + 30} ${yOk - gap - 8} L ${x + 30} ${yOk - 4}`, t.go, "go", { sw: 2.5 }));
  out.push(box(t, id, x, yOk, w, 58, "ok"), text(x + w / 2, yOk + 36, "ISO copied and SHA-256 verified.", { size: S, weight: 800, fill: t.ink, anchor: "middle" }));
  // The error path: down the right side to the error box below the success box.
  const yBad = yOk + 58 + 40, bh = 176;
  out.push(flow(id, `M${busX} ${y0 + h + gap + h / 2} L ${busX} ${yBad - 4}`, t.bad, "bad", { sw: 2.5, dash: "5 6" }));
  out.push(box(t, id, x, yBad, busX + 16 - x, bh, "bad"));
  out.push(text(x + 24, yBad + 40, ["Any error, a different SHA-256", "or Ctrl+C:"], { size: S, weight: 800, fill: t.bad, lh: 1.3 }));
  out.push(text(x + 24, yBad + 104, ["the utility removes the temp file where", "possible and stops. Linux then goes on", "with the next ISO, except after Ctrl+C."], { size: S, fill: t.ink, lh: 1.3 }));
  return svg(t, id, W, yBad + bh + 30, 53, out.join("\n"), "The verified copy, on Windows, macOS and Linux. 1, check: the same USB, enough free space, the FAT32 file size limit, and no file with the same name; on Linux, an ISO whose name is already on the USB is skipped. 2, write to a temp file named .ventoy-copy-something; on macOS and Linux, the file is hidden. 3, copy, with progress: on Windows and macOS, the percent, GiB copied, MiB per second and time left; on Linux, the bytes copied and the speed. 4, flush the data to the USB. 5, skip the cache, so that the copy is read from the USB: on macOS, unmount the USB, mount it again, and check that it is the same USB; on Linux, read the copy with O_DIRECT. 6, read the SHA-256 of the source and of the copy. 7, if they are the same, rename the temp file to the ISO name; it never overwrites a file. Then: ISO copied and SHA-256 verified. After step 2, any error, a different SHA-256 or Ctrl+C makes the utility remove the temp file where possible, and stop. Linux then goes on with the next ISO, except after Ctrl+C.");
}

/** A tip: a USB stick in a round badge on the left, and the tip in a framed card to the right. */
const tip = (lines, label, seed, accent = "led") => (t, id) => {
  const a = t[accent];
  const W = 1100, size = 24, lh = 1.4, H = 120 + lines.length * size * lh + 30;
  const sx = 210, sy = 30, sw = W - 36 - sx, sh = H - 60;
  const body = [
    circle(110, H / 2, 82, { fill: a, opacity: t.glowOp, filter: `url(#${id}-glow)` }),
    circle(110, H / 2, 74, { fill: t.tile, stroke: a, sw: 3 }),
    stick(t, id, 82, H / 2 - 22, 80, 44, "", 0),
    box(t, id, sx, sy, sw, sh, "plain"),
    rect(sx, sy, 8, sh, { rx: 4, fill: a }),
    text(sx + 40, sy + 52, "TIP", { size: SMALL, weight: 800, fill: a, ls: 2 }),
    text(sx + 40, sy + 94, lines, { size, weight: 600, fill: t.ink, lh }),
  ].join("\n");
  return svg(t, id, W, Math.round(H), seed, body, label);
};

const GRAPHICS = {
  hero, pick, journey, copy,
  "tip-yes": tip(["Type YES only after you check the disk name and size.", "At “Select USB by list number”, type the number", "in [ ], not the disk number or the drive letter."], "Tip: type YES only after you check the disk name and size. At Select USB by list number, type the number in square brackets, not the disk number or the drive letter.", 61),
  "tip-mactoy": tip(["Check Mactoy before you give it Full Disk Access:", "the .dmg must match its .sha256 file, and", "spctl -a -vv must show “accepted” and", "“source=Notarized Developer ID”."], "Tip: check Mactoy before you give it Full Disk Access. The SHA-256 of the .dmg file must match its .sha256 file, and spctl -a -vv must show accepted and source=Notarized Developer ID.", 67, "iso"),
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
