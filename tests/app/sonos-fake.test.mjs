// The fake Sonos players (tests/sonos/fake-sonos.mjs) that the dev server, the contract test and
// the browser check talk to: they answer as the real players do (tests/sonos/real/), keep what they
// were told, and refuse what a real player refuses.
//   node --test tests/app/

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { startFakeSonos } from "../sonos/fake-sonos.mjs";

const fixture = (name) => readFileSync(new URL(`../sonos/${name}`, import.meta.url), "utf8");

async function soap(port, ip, path, urn, action, body = "") {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: "POST",
    headers: { "Content-Type": 'text/xml; charset="utf-8"', SOAPACTION: `"${urn}#${action}"`, "X-Fake-Sonos-Host": ip },
    body: `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:${action} xmlns:u="${urn}">${body}</u:${action}></s:Body></s:Envelope>`,
  });
  return { status: response.status, text: await response.text() };
}
const AVT = ["/MediaRenderer/AVTransport/Control", "urn:schemas-upnp-org:service:AVTransport:1"];
const RC = ["/MediaRenderer/RenderingControl/Control", "urn:schemas-upnp-org:service:RenderingControl:1"];
const ZGT = ["/ZoneGroupTopology/Control", "urn:schemas-upnp-org:service:ZoneGroupTopology:1"];

test("the fake players answer as the owner's real ones, and as the made answers say", async () => {
  const fake = await startFakeSonos({ port: 0, kind: "real" });
  try {
    const replies = await (await fetch(`http://127.0.0.1:${fake.port}/fake/ssdp`)).json();
    assert.equal(replies.length, 3);
    assert.equal(replies[0], fixture("real/ssdp_response.txt").replace(/\r?\n/g, "\r\n"), "the first player answers the search as the real one");
    assert.equal((await soap(fake.port, "192.168.50.12", ...ZGT, "GetZoneGroupState")).text, fixture("real/zone_group_state.xml"));
    assert.equal((await soap(fake.port, "192.168.50.11", ...AVT, "GetPositionInfo", "<InstanceID>0</InstanceID>")).text, fixture("real/position_info_spotify_connect.xml"));
    assert.equal((await soap(fake.port, "192.168.50.11", ...RC, "GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>")).text, fixture("real/volume.xml"));
    assert.equal((await soap(fake.port, "192.168.50.11", ...AVT, "GetTransportInfo", "<InstanceID>0</InstanceID>")).text, fixture("real/transport_info_paused.xml"));
  } finally {
    await fake.close();
  }
});

test("they keep what they are told, and refuse what a real player refuses", async () => {
  const fake = await startFakeSonos({ port: 0 });
  try {
    const radio = "192.168.50.13";
    const paused = await soap(fake.port, radio, ...AVT, "Pause", "<InstanceID>0</InstanceID>");
    assert.equal(paused.status, 500, "a radio station cannot pause");
    assert.match(paused.text, /<errorCode>701<\/errorCode>/);
    assert.equal((await soap(fake.port, radio, ...AVT, "Next", "<InstanceID>0</InstanceID>")).status, 500, "nor skip");
    assert.equal((await soap(fake.port, radio, ...AVT, "Stop", "<InstanceID>0</InstanceID>")).status, 200);
    assert.match((await soap(fake.port, radio, ...AVT, "GetTransportInfo", "<InstanceID>0</InstanceID>")).text, /<CurrentTransportState>STOPPED</);
    await soap(fake.port, "192.168.50.12", ...RC, "SetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>33</DesiredVolume>");
    assert.match((await soap(fake.port, "192.168.50.12", ...RC, "GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>")).text, /<CurrentVolume>33</);
    await soap(fake.port, "192.168.50.11", ...AVT, "Next", "<InstanceID>0</InstanceID>");
    assert.equal((await soap(fake.port, "192.168.50.11", ...AVT, "GetPositionInfo", "<InstanceID>0</InstanceID>")).text, fixture("made/position_info_track_hebrew.xml"));
    assert.equal((await soap(fake.port, "192.168.50.11", ...AVT, "BecomeCoordinatorOfStandaloneGroup", "<InstanceID>0</InstanceID>")).status, 500, "no grouping");
    const art = await fetch(`http://127.0.0.1:${fake.port}/getaa?s=1&u=x`, { headers: { "X-Fake-Sonos-Host": "192.168.50.11" } });
    assert.equal(art.headers.get("content-type"), "image/png");
    assert.deepEqual([...new Uint8Array(await art.arrayBuffer()).slice(0, 4)], [0x89, 0x50, 0x4e, 0x47]);
    const unknown = await fetch(`http://127.0.0.1:${fake.port}/getaa?s=1`, { headers: { "X-Fake-Sonos-Host": "203.0.113.1" } });
    assert.equal(unknown.status, 404, "no player at another address");
  } finally {
    await fake.close();
  }
});
