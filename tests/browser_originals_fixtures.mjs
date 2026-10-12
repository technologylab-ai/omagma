// Literal provider fixtures, independent of Omagma's MIME/original assembler.
// Addresses, OAuth handles, HTML and file bytes are entirely synthetic.
const addresses = ["ada.browser@example.test", "bea.browser@example.test"];
const owners = ["Ada", "Bea"];
export const originalRecipients = Object.freeze({ reply: "reply.synthetic@example.test", toPeer: "to.peer@example.test", ccPeer: "cc.peer@example.test" });
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP1kAAAAASUVORK5CYII=", "base64");
const foldBase64 = bytes => bytes.toString("base64").match(/.{1,76}/g)?.join("\r\n") || "";

export function originalFixture(index, messageIndex = 0) {
  const owner = owners[index], key = owner.toLowerCase();
  const cid = `source-artwork-${key}@fixture.invalid`;
  const location = `https://invalid-resource.example.test/source-${key}.css`;
  const cssText = `.original-card{border:3px solid #31708f;background-image:url("cid:${cid}")}@media(max-width:600px){.original-card{width:100%!important}}`;
  const inlineStyle = ".original-title{color:#913175;font-weight:700}@media(max-width:600px){.original-title{font-size:20px}}";
  const table = `<table role="presentation" data-layout="original-${key}" class="original-card" style="border-collapse:collapse;width:480px"><tr><td><h1 class="original-title">${owner} original formatting</h1><p>Original café, 日本語 and rocket 🚀.</p><img src="cid:${cid}" width="1" height="1"><a href="https://example.test/source-link">Source link</a></td></tr></table>`;
  const html = `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><style>${inlineStyle}</style><link rel="stylesheet" href="${location}"></head><body><!--[if mso]><div data-conditional="original">Outlook fixture</div><![endif]-->${table}<script>window.__originalInjected="must-never-run";</script><img src="https://invalid-resource.example.test/remote-${key}.png" onerror="window.__originalInjected='image-error'"><p data-original-tail="${key}">Original tail preserved.</p></body></html>`;
  const document = Buffer.concat([Buffer.from(`%PDF-1.4\nSynthetic ordinary ${owner} source file.\n`, "utf8"), Buffer.from([0, 1, 127, 128, 254, 255]), Buffer.from("\n%%EOF\n")]);
  const suffix = messageIndex ? `-${messageIndex}` : "";
  let files = [
    { id: `${key}-source-image${suffix}`, filename: `source-${key}.png`, mimeType: "image/png", bytes: messageIndex === 4 ? Buffer.alloc(1850 * 1024, 0xa5) : messageIndex === 8 ? Buffer.alloc(1200 * 1024, 0x7b) : png, contentId: cid, disposition: "inline" },
    { id: `${key}-source-style${suffix}`, filename: `source-${key}.css`, mimeType: "text/css", bytes: Buffer.from(cssText), contentLocation: location, disposition: "inline" },
    { id: `${key}-source-document${suffix}`, filename: `design-notes-${key}.pdf`, mimeType: "application/pdf", bytes: messageIndex === 5 ? Buffer.alloc(2 * 1024 * 1024 + 1, 0x5a) : document, disposition: "attachment" },
  ];
  const headers = [
    { name: "From", value: "Morgan Browser <morgan@example.test>" },
    { name: "Reply-To", value: `Replies <${originalRecipients.reply}>` },
    { name: "To", value: `${owner} Browser <${addresses[index]}>, "Recipient, To" <${originalRecipients.toPeer}>, Reply copy <${originalRecipients.reply.toUpperCase()}>, Verified alias <${key}.alias@example.test>` },
    { name: "Cc", value: `Self copy <${addresses[index].toUpperCase()}>, Duplicate To <${originalRecipients.toPeer.toUpperCase()}>, CC Peer <${originalRecipients.ccPeer}>` },
    { name: "Subject", value: `${owner} ${messageIndex === 2 ? "plain original" : messageIndex === 3 ? "attachment-only original" : messageIndex === 4 ? "oversized original resource" : messageIndex === 5 ? "oversized ordinary file" : messageIndex === 6 ? "many ordinary files" : messageIndex === 8 ? "medium original resource" : "original formatting"}` },
    { name: "Date", value: "Mon, 12 Oct 2026 10:00:00 +0000" },
    { name: "Message-ID", value: `<${key}-original-source${suffix}@example.test>` },
    { name: "References", value: "<prior-original-thread@example.test>" },
  ];
  const outer = `synthetic-${key}-raw-mixed`, related = `synthetic-${key}-raw-related`;
  const entity = (file) => [
    `Content-Type: ${file.mimeType}; name="${file.filename}"`,
    "Content-Transfer-Encoding: base64", `Content-Disposition: ${file.disposition}; filename="${file.filename}"`,
    ...(file.contentId ? [`Content-ID: <${file.contentId}>`] : []),
    ...(file.contentLocation ? [`Content-Location: ${file.contentLocation}`] : []),
    "", foldBase64(file.bytes), "",
  ].join("\r\n");
  const raw = Buffer.from([
    ...headers.map(header => `${header.name}: ${header.value}`), "MIME-Version: 1.0", `Content-Type: multipart/mixed; boundary="${outer}"`, "",
    `--${outer}`, `Content-Type: multipart/related; boundary="${related}"`, "",
    `--${related}`, "Content-Type: text/html; charset=UTF-8", "Content-Transfer-Encoding: base64", "", foldBase64(Buffer.from(html)), "",
    ...files.slice(0, 2).flatMap(file => [`--${related}`, entity(file)]), `--${related}--`, "",
    `--${outer}`, entity(files[2]), `--${outer}--`, "",
  ].join("\r\n"), "utf8");
  if ([2, 3, 5, 6].includes(messageIndex)) {
    const plain = messageIndex !== 3 ? `Literal ${owner} plain original.\nKeep every original file.\n` : "";
    files = messageIndex === 6 ? Array.from({ length: 17 }, (_, part) => ({ ...files[2], id: `${key}-source-document-6-${part}`, filename: `ordinary-${key}-${part}.pdf` })) : [files[2]];
    const rawSimple = Buffer.from([
      ...headers.map(header => `${header.name}: ${header.value}`), "MIME-Version: 1.0", `Content-Type: multipart/mixed; boundary="${outer}"`, "",
      ...(plain ? [`--${outer}`, "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "", foldBase64(Buffer.from(plain)), ""] : []),
      ...files.flatMap(file => [`--${outer}`, entity(file)]), `--${outer}--`, "",
    ].join("\r\n"));
    return { owner, key, account: addresses[index], messageIndex, plain, html: "", files, headers, raw: rawSimple };
  }
  return { owner, key, account: addresses[index], messageIndex, html, inlineStyle, table, cssText, cid, location, files, headers, raw };
}

export function originalProviderMessage(accountIndex, format, messageIndex = 0) {
  const source = originalFixture(accountIndex, messageIndex);
  const message = { id: `${source.key}-message-${messageIndex}`, threadId: `${source.key}-thread-${messageIndex}`, labelIds: ["INBOX", "UNREAD"],
    snippet: `${source.owner} original source preview ${messageIndex}`, historyId: "1200", internalDate: String(1791802800000 - messageIndex * 60000), sizeEstimate: source.raw.length };
  if (format === "raw") return { id: message.id, raw: source.raw.toString("base64url") };
  message.payload = { partId: "", mimeType: "multipart/mixed", filename: "", headers: source.headers, body: { size: 0 } };
  if ([2, 3, 5, 6].includes(messageIndex)) {
    if (format !== "metadata") message.payload.parts = [
      ...(source.plain ? [{ partId: "0", mimeType: "text/plain", filename: "", headers: [{ name: "Content-Type", value: "text/plain; charset=UTF-8" }], body: { size: Buffer.byteLength(source.plain), data: Buffer.from(source.plain).toString("base64url") } }] : []),
      ...source.files.map((file, index) => providerPart(file, String(index + 1))),
    ];
    return message;
  }
  if (format !== "metadata") message.payload.parts = [
    { partId: "0", mimeType: "multipart/related", filename: "", headers: [], body: { size: 0 }, parts: [
      { partId: "0.0", mimeType: "text/html", filename: "", headers: [{ name: "Content-Type", value: "text/html; charset=UTF-8" }], body: { size: Buffer.byteLength(source.html), data: Buffer.from(source.html).toString("base64url") } },
      ...source.files.slice(0, 2).map((file, index) => providerPart(file, `0.${index + 1}`)),
    ] }, providerPart(source.files[2], "1"),
  ];
  return message;
}

function providerPart(file, partId) {
  return { partId, mimeType: file.mimeType, filename: file.filename, headers: [
    { name: "Content-Disposition", value: `${file.disposition}; filename="${file.filename}"` },
    ...(file.contentId ? [{ name: "Content-ID", value: `<${file.contentId}>` }] : []),
    ...(file.contentLocation ? [{ name: "Content-Location", value: file.contentLocation }] : []),
  ], body: { attachmentId: file.id, size: file.bytes.length } };
}

export function originalAttachment(accountIndex, id, messageIndex = 0) {
  const file = originalFixture(accountIndex, messageIndex).files.find(file => file.id === id);
  if (!file) throw new Error("synthetic attachment is not owned by this actor");
  return { size: file.bytes.length, data: file.bytes.toString("base64url") };
}

// A small independent wire decoder for the fixture oracle. It never invokes
// the application's MIME builder or parses source HTML into the browser DOM.
export function decodeOutgoingOriginal(raw) {
  // MIME delimiters index octets. Preserve unencoded message/global/rfc822
  // leaves as bytes rather than passing them through a lossy UTF-8 decoder.
  raw = (Buffer.isBuffer(raw) ? raw : Buffer.from(raw, "utf8")).toString("latin1");
  const leaves = [];
  const headerObject = value => {
    value = Buffer.from(value, "latin1").toString("utf8");
    const headers = {};
    for (const line of value.replace(/\r\n[ \t]+/g, " ").split("\r\n")) {
      const colon = line.indexOf(":");
      if (colon <= 0) throw new Error("outgoing original contains a malformed MIME header");
      const name = line.slice(0, colon).toLowerCase();
      if (Object.hasOwn(headers, name)) throw new Error("outgoing original contains duplicate MIME headers");
      headers[name] = line.slice(colon + 1).trim();
    }
    return headers;
  };
  const split = raw.indexOf("\r\n\r\n");
  if (split < 0) throw new Error("outgoing original has no header separator");
  const headers = headerObject(raw.slice(0, split));
  function parse(headers, body, depth = 0) {
    if (depth > 8 || leaves.length >= 16) throw new Error("outgoing original exceeds the fixture MIME bounds");
    const type = headers["content-type"] || "";
    if (/^multipart\//i.test(type)) {
      const boundary = type.match(/boundary=(?:"([^"\r\n]+)"|([^;\s]+))/i);
      if (!boundary) throw new Error("outgoing original multipart has no boundary");
      const delimiter = "--" + (boundary[1] || boundary[2]);
      if (!body.includes(delimiter + "--")) throw new Error("outgoing original multipart is incomplete");
      for (const part of body.split(delimiter).slice(1)) {
        if (part.startsWith("--")) break;
        const entity = part.replace(/^\r\n/, "");
        const separator = entity.indexOf("\r\n\r\n");
        if (separator < 0) throw new Error("outgoing original MIME part lacks its headers");
        parse(headerObject(entity.slice(0, separator)), entity.slice(separator + 4), depth + 1);
      }
    } else {
      let bytes;
      if (headers["content-transfer-encoding"] === "base64") {
        const encoded = body.replace(/\s/g, "");
        if (!/^[a-zA-Z0-9+/]*={0,2}$/.test(encoded)) throw new Error("outgoing fixture MIME leaf has invalid base64");
        bytes = Buffer.from(encoded, "base64");
        if (bytes.toString("base64").replace(/=+$/, "") !== encoded.replace(/=+$/, "")) throw new Error("outgoing fixture MIME leaf has noncanonical base64");
      } else if (headers["content-transfer-encoding"] === "8bit" && /^message\/(rfc822|global)(;|$)/i.test(type)) {
        if (!body.endsWith("\r\n")) throw new Error("original message lacks its MIME boundary separator");
        bytes = Buffer.from(body.slice(0, -2), "latin1"); // Remove separator, preserving the source's own trailing CRLF.
      } else throw new Error("outgoing fixture MIME leaf has an unsupported transfer encoding");
      const disposition = headers["content-disposition"] || "";
      let name = (disposition.match(/filename="([^"\r\n]*)"/i) || type.match(/name="([^"\r\n]*)"/i))?.[1] || "";
      const continued = [...disposition.matchAll(/filename\*(\d+)\*=([^;]*)/gi)].sort((a, b) => Number(a[1]) - Number(b[1]));
      if (continued.length) {
        if (continued.some((part, index) => Number(part[1]) !== index) || !/^UTF-8''/i.test(continued[0][2].trim())) throw new Error("invalid RFC2231 filename continuation");
        name = decodeURIComponent(continued.map(part => part[2].trim()).join("").replace(/^UTF-8''/i, ""));
      }
      leaves.push({ headers, type: type.split(";")[0].toLowerCase(), disposition: disposition.split(";")[0].toLowerCase(), filename: name,
        contentId: (headers["content-id"] || "").replace(/^<|>$/g, ""), contentLocation: headers["content-location"] || "", bytes,
        text: /^text\//i.test(type) ? bytes.toString("utf8").replace(/\r\n/g, "\n") : null });
    }
  }
  parse(headers, raw.slice(split + 4));
  return { headers, leaves, body: leaves.find(part => part.type === "text/plain")?.text,
    html: leaves.find(part => part.type === "text/html")?.text };
}
