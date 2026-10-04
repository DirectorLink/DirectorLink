// Fake Sonos players on one local port, for the dev server, the contract test, the app's tests and
// the browser check (the driver's own tests use their Lua twin, driver/tests/sonos_fake.lua). They
// answer the SOAP calls DirectorLink sends with the players' own XML: the owner's real answers,
// anonymised (tests/sonos/real/), and answers made in the same shapes (tests/sonos/made/).
//
//   node tests/sonos/fake-sonos.mjs [--port 8212] [--household grouped|real]
//
// Every player answers on the one port: the dev server sends each request with the player's own
// address in X-Fake-Sonos-Host (scripts/dev_server.py --sonos). GET /fake/ssdp lists the players'
// answers to a search; GET /fake/state shows what each player is doing. Rooms join and leave groups
// (1.8.0): the zone group state they answer follows.

import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";
import { deflateSync } from "node:zlib";

const DIR = new URL("./", import.meta.url);
const files = new Map();
export function fixture(name) {
  if (!files.has(name)) files.set(name, readFileSync(new URL(name, DIR), "utf8"));
  return files.get(name);
}

const URNS = {
  AVTransport: "urn:schemas-upnp-org:service:AVTransport:1",
  RenderingControl: "urn:schemas-upnp-org:service:RenderingControl:1",
  ZoneGroupTopology: "urn:schemas-upnp-org:service:ZoneGroupTopology:1",
  ContentDirectory: "urn:schemas-upnp-org:service:ContentDirectory:1",
};
const SERVICE_OF = {
  "/MediaRenderer/AVTransport/Control": "AVTransport",
  "/MediaRenderer/RenderingControl/Control": "RenderingControl",
  "/ZoneGroupTopology/Control": "ZoneGroupTopology",
  "/MediaServer/ContentDirectory/Control": "ContentDirectory",
};
// What each kind of thing playing answers: GetPositionInfo and GetMediaInfo.
const PLAYING = {
  connect: ["real/position_info_spotify_connect.xml", "real/media_info_spotify_connect.xml"],
  track: ["made/position_info_track.xml", "made/media_info_queue.xml"],
  track2: ["made/position_info_track_hebrew.xml", "made/media_info_queue.xml"],
  radio: ["made/position_info_radio.xml", "made/media_info_radio.xml"],
  member: ["made/position_info_group_member.xml", "made/position_info_group_member.xml"],
};

const envelope = (action, service, body = "") =>
  `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:${action}Response xmlns:u="${URNS[service]}">${body}</u:${action}Response></s:Body></s:Envelope>`;
const unescape = (text) => text.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");
export function argument(body, name) {
  const match = String(body || "").match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`));
  return match ? unescape(match[1]) : null;
}

// A small square picture in two colours (PNG), as album art.
function picture(seed) {
  const size = 96;
  const colours = [
    [[37, 99, 235], [250, 204, 21]],
    [[219, 39, 119], [56, 189, 248]],
    [[22, 163, 74], [249, 115, 22]],
  ][seed % 3];
  const rows = [];
  for (let y = 0; y < size; y++) {
    const row = [0];
    for (let x = 0; x < size; x++) {
      const [a, b] = colours;
      const t = (x + y) / (2 * size);
      const ring = Math.hypot(x - size / 2, y - size / 2) < size / 4;
      const colour = ring ? b : a.map((value, index) => Math.round(value * (1 - t) + b[index] * t * 0.4));
      row.push(...colour);
    }
    rows.push(Buffer.from(row));
  }
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (buffer) => {
    let c = 0xffffffff;
    for (const byte of buffer) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const sum = Buffer.alloc(4);
    sum.writeUInt32BE(crc(body));
    return Buffer.concat([length, body, sum]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;
  header[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(Buffer.concat(rows))),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const escape = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// The zone groups of a GetZoneGroupState answer: [{ coordinator, parts: [{ id, text }] }], a part
// being a room as Sonos shows it (a stereo pair's hidden speaker goes with its room; a Boost is a
// part of its own), and what goes around them (1.8.0: rooms join and leave groups).
function zoneGroups(topology) {
  const [, before, inner, after] = topology.match(/^([\s\S]*?<ZoneGroupState>)([\s\S]*?)(<\/ZoneGroupState>[\s\S]*)$/);
  const [, head, body, tail] = unescape(inner).match(/^([\s\S]*?<ZoneGroups>)([\s\S]*?)(<\/ZoneGroups>[\s\S]*)$/);
  const groups = [];
  for (const [, attrs, members] of body.matchAll(/<ZoneGroup ([^>]*)>([\s\S]*?)<\/ZoneGroup>/g)) {
    const group = { coordinator: attrs.match(/Coordinator="([^"]+)"/)[1], parts: [] };
    for (const [text, tag] of members.matchAll(/<ZoneGroupMember ([^>]*?)(?:\/>|>[\s\S]*?<\/ZoneGroupMember>)/g)) {
      const hidden = tag.includes('Invisible="1"') && !tag.includes('IsZoneBridge="1"');
      if (hidden && group.parts.length) group.parts[group.parts.length - 1].text += text;
      else group.parts.push({ id: tag.match(/UUID="([^"]+)"/)[1], text });
    }
    groups.push(group);
  }
  return { groups, frame: [before, head, tail, after] };
}

function zoneGroupState({ groups, frame }) {
  const list = groups.map((group, index) => `<ZoneGroup Coordinator="${group.coordinator}" ID="${group.coordinator}:${900 + index + 1}">${group.parts.map((part) => part.text).join("")}</ZoneGroup>`);
  return frame[0] + escape(frame[1] + list.join("") + frame[2]) + frame[3];
}

// The players of a household: "grouped" (Kitchen leads Living Room and plays a track, Bedroom plays
// the radio, TV Room is paused in Spotify Connect, a stereo pair and a Boost) or "real" (the owner's
// three rooms, each on its own, paused in Spotify Connect).
export function household(kind = "grouped") {
  const players = new Map();
  const add = (ip, id, playing, volume, transport = "PAUSED_PLAYBACK") =>
    players.set(ip, { ip, id, playing, volume, muted: false, transport, queue: [] });
  let topology;
  if (kind === "real") {
    topology = fixture("real/zone_group_state.xml");
    add("192.168.50.11", "RINCON_000E58A0000101400", "connect", 58);
    add("192.168.50.12", "RINCON_000E58A0000201400", "connect", 45);
    add("192.168.50.13", "RINCON_000E58A0000301400", "connect", 100);
  } else {
    topology = fixture("made/zone_group_state_grouped.xml");
    add("192.168.50.11", "RINCON_000E58A0000101400", "track", 30, "PLAYING");
    add("192.168.50.12", "RINCON_000E58A0000201400", "member", 20);
    add("192.168.50.13", "RINCON_000E58A0000301400", "radio", 25, "PLAYING");
    add("192.168.50.14", "RINCON_000E58A0000401400", "connect", 40);
    add("192.168.50.15", "RINCON_000E58A0000501400", "member", 40);
    add("192.168.50.16", "RINCON_000E58A0000601400", "member", 0);
    add("192.168.50.17", "RINCON_000E58A0000701400", "member", 25);
  }
  const calls = [];
  const byId = (id) => [...players.values()].find((player) => player.id === id);
  // The room `id` joins the group led by `coordinatorId` (null: it leaves its group), as Sonos does
  // it: its zone group state changes. False when there is no such group or room.
  function regroup(id, coordinatorId) {
    const state = zoneGroups(topology);
    const from = state.groups.find((group) => group.parts.some((part) => part.id === id));
    const target = coordinatorId ? state.groups.find((group) => group.coordinator === coordinatorId) : null;
    if (!from || (coordinatorId && (!target || target === from)) || (!coordinatorId && from.parts.length === 1)) return false;
    const part = from.parts.splice(from.parts.findIndex((entry) => entry.id === id), 1)[0];
    const player = byId(id);
    if (!from.parts.length) state.groups.splice(state.groups.indexOf(from), 1);
    else if (from.coordinator === id) {
      // The others go on together, led by the next of them.
      from.coordinator = from.parts[0].id;
      const led = byId(from.coordinator);
      if (led && player) Object.assign(led, { playing: player.playing, transport: player.transport });
    }
    if (target) {
      target.parts.push(part);
      if (player) player.playing = "member";
    } else {
      state.groups.push({ coordinator: id, parts: [part] });
      if (player) Object.assign(player, { playing: "track", transport: "STOPPED" });
    }
    topology = zoneGroupState(state);
    return true;
  }
  const fault = (code) => ({ status: 500, type: 'text/xml; charset="utf-8"', body: fixture("made/fault_701.xml").replace("701", String(code)) });
  const ok = (body) => ({ status: 200, type: 'text/xml; charset="utf-8"', body });

  function answer(player, method, path, headers, body) {
    if (method === "GET") {
      if (path.startsWith("/getaa?")) {
        const seed = player.playing === "radio" ? 1 : player.playing === "track2" ? 2 : 0;
        return { status: 200, type: "image/png", body: picture(seed) };
      }
      return { status: 404, type: "text/plain", body: "" };
    }
    const service = SERVICE_OF[path];
    const match = String(headers.soapaction || "").match(/^"(.*)#(\w+)"$/);
    if (!service || !match || match[1] !== URNS[service]) return fault(401);
    const action = match[2];
    calls.push({ ip: player.ip, action, body });
    const [position, media] = PLAYING[player.playing];
    switch (action) {
      case "GetZoneGroupState":
        return ok(topology);
      case "GetTransportInfo":
        return ok(fixture("real/transport_info_paused.xml").replace("PAUSED_PLAYBACK", player.transport));
      case "GetPositionInfo":
        return ok(fixture(position));
      case "GetMediaInfo":
        return ok(fixture(media));
      case "GetVolume":
        return ok(fixture("real/volume.xml").replace(/<CurrentVolume>\d+<\/CurrentVolume>/, `<CurrentVolume>${player.volume}</CurrentVolume>`));
      case "GetMute":
        return ok(fixture("real/mute.xml").replace(/<CurrentMute>\d<\/CurrentMute>/, `<CurrentMute>${player.muted ? 1 : 0}</CurrentMute>`));
      case "Browse":
        return argument(body, "ObjectID") === "FV:2" ? ok(fixture("made/favorites.xml")) : fault(701);
      case "Play":
        player.transport = "PLAYING";
        break;
      case "Pause":
        if (player.playing === "radio") return fault(701);
        player.transport = "PAUSED_PLAYBACK";
        break;
      case "Stop":
        player.transport = "STOPPED";
        break;
      case "Next":
      case "Previous":
        if (player.playing === "radio") return fault(711);
        player.playing = player.playing === "track" ? "track2" : "track";
        break;
      case "SetVolume":
        player.volume = Number(argument(body, "DesiredVolume"));
        break;
      case "SetMute":
        player.muted = argument(body, "DesiredMute") === "1";
        break;
      case "RemoveAllTracksFromQueue":
        player.queue = [];
        break;
      case "AddURIToQueue":
        player.queue.push(argument(body, "EnqueuedURI"));
        return ok(envelope(action, service, "<FirstTrackNumberEnqueued>1</FirstTrackNumberEnqueued><NumTracksAdded>1</NumTracksAdded><NewQueueLength>1</NewQueueLength>"));
      case "SetAVTransportURI": {
        const uri = argument(body, "CurrentURI") || "";
        const coordinator = uri.match(/^x-rincon:(RINCON_[0-9A-Fa-f]+)$/);
        if (coordinator) {
          // Joins that group (1.8.0): only a group's coordinator, not itself.
          if (!regroup(player.id, coordinator[1])) return fault(701);
          break;
        }
        player.playing = uri.startsWith("x-rincon-queue:") ? "track" : "radio";
        player.transport = "STOPPED";
        break;
      }
      case "BecomeCoordinatorOfStandaloneGroup":
        regroup(player.id, null);
        break;
      default:
        return fault(401);
    }
    return ok(envelope(action, service));
  }

  function searchReplies() {
    const template = fixture("real/ssdp_response.txt").replace(/\r?\n/g, "\r\n");
    return [...players.values()]
      .filter((player) => topology.includes(player.id))
      .map((player) => template.replaceAll("192.168.50.11", player.ip).replaceAll("RINCON_000E58A0000101400", player.id));
  }

  return { players, calls, answer, searchReplies, topology: () => topology };
}

// Serves a household on `port` (0: any free one). Resolves to { port, home, close }.
export function startFakeSonos({ port = 8212, kind = "grouped", host = "127.0.0.1" } = {}) {
  const home = household(kind);
  const server = createServer((request, response) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const url = new URL(request.url, "http://fake");
      if (url.pathname === "/fake/ssdp") {
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(JSON.stringify(home.searchReplies()));
        return;
      }
      if (url.pathname === "/fake/state") {
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(JSON.stringify({ players: [...home.players.values()], calls: home.calls }));
        return;
      }
      const player = home.players.get(String(request.headers["x-fake-sonos-host"] || ""));
      if (!player) {
        response.writeHead(404, { "Content-Type": "text/plain" });
        response.end("no such player");
        return;
      }
      const result = home.answer(player, request.method, url.pathname + url.search, request.headers, Buffer.concat(chunks).toString("utf8"));
      response.writeHead(result.status, { "Content-Type": result.type });
      response.end(result.body);
    });
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => {
      resolve({ port: server.address().port, home, close: () => new Promise((done) => server.close(done)) });
    });
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const option = (name, fallback) => {
    const index = process.argv.indexOf(`--${name}`);
    return index > 0 ? process.argv[index + 1] : fallback;
  };
  const fake = await startFakeSonos({ port: Number(option("port", 8212)), kind: option("household", "grouped") });
  console.log(`FAKE SONOS ${fake.port}`);
}
