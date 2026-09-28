// A QR code on a canvas, for invitation links (vendor/qrcodegen.js). Dark on white with a quiet
// zone, whatever the theme, so phone cameras read it.

import qrcodegen from "./vendor/qrcodegen.js";

export function qrCanvas(text, { size = 240, label = "" } = {}) {
  const code = qrcodegen.QrCode.encodeText(text, qrcodegen.QrCode.Ecc.MEDIUM);
  const border = 4;
  const modules = code.size + border * 2;
  const scale = Math.max(2, Math.floor(size / modules));
  const canvas = document.createElement("canvas");
  canvas.width = modules * scale;
  canvas.height = modules * scale;
  canvas.className = "qr-code";
  canvas.setAttribute("role", "img");
  canvas.setAttribute("aria-label", label);
  const context = canvas.getContext("2d");
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "#000000";
  for (let y = 0; y < code.size; y += 1) {
    for (let x = 0; x < code.size; x += 1) {
      if (code.getModule(x, y)) {
        context.fillRect((x + border) * scale, (y + border) * scale, scale, scale);
      }
    }
  }
  return canvas;
}
