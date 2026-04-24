/**
 * End-to-end integration test: spin up the actual WebSocket server, connect
 * two ws clients, walk through the full lobby -> round -> confirm flow, and
 * assert the messages each client receives.
 *
 * This is the test that catches drift between the protocol document, the zod
 * schemas, and the engine wiring in `index.ts`.
 */
import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import WebSocket from "ws";
import { createServer } from "../src/index.js";
import { randomUUID } from "node:crypto";

let server: Awaited<ReturnType<typeof createServer>>;
const PORT = 18765;

before(async () => {
  server = createServer(PORT);
});

after(async () => {
  await server.stop();
});

interface Client {
  ws: WebSocket;
  inbox: any[];
  send: (msg: object) => void;
  waitFor: (predicate: (m: any) => boolean, timeoutMs?: number) => Promise<any>;
  close: () => void;
}

function connect(displayName: string, capabilities: string[] = ["ble", "bump"]): Promise<Client> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
    const inbox: any[] = [];
    const waiters: Array<{ predicate: (m: any) => boolean; resolve: (m: any) => void }> = [];

    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString("utf-8"));
      inbox.push(msg);
      for (let i = waiters.length - 1; i >= 0; i--) {
        if (waiters[i]!.predicate(msg)) {
          waiters[i]!.resolve(msg);
          waiters.splice(i, 1);
        }
      }
    });
    ws.on("open", () => {
      const client: Client = {
        ws,
        inbox,
        send: (msg) => ws.send(JSON.stringify(msg)),
        waitFor: (predicate, timeoutMs = 2000) =>
          new Promise((res, rej) => {
            const existing = inbox.find(predicate);
            if (existing) return res(existing);
            const timer = setTimeout(() => rej(new Error("waitFor timeout")), timeoutMs);
            waiters.push({
              predicate,
              resolve: (m) => {
                clearTimeout(timer);
                res(m);
              },
            });
          }),
        close: () => ws.close(),
      };
      client.send({
        type: "hello",
        v: 1,
        deviceId: randomUUID(),
        displayName,
        appVersion: "test",
        platform: "ios",
        osVersion: "17",
        capabilities,
      });
      client
        .waitFor((m) => m.type === "hello_ack")
        .then(() => resolve(client))
        .catch(reject);
    });
    ws.on("error", reject);
  });
}

describe("integration: full happy-path round", () => {
  it("two clients can host, join, start, evidence, and confirm a pair", async () => {
    const host = await connect("Host");
    host.send({ type: "create_room", v: 1, mode: "musical_chairs", settings: { roundSeconds: 30, maxPlayers: 16 } });
    const hostState = await host.waitFor((m) => m.type === "room_state");
    const roomCode: string = hostState.roomCode;
    assert.match(roomCode, /^[A-Z0-9]{4}$/);

    const guest = await connect("Guest");
    guest.send({ type: "join_room", v: 1, roomCode });
    await guest.waitFor((m) => m.type === "room_state" && m.players.length === 2);
    await host.waitFor((m) => m.type === "room_state" && m.players.length === 2);

    host.send({ type: "start_round", v: 1 });
    const hostAssign = await host.waitFor((m) => m.type === "pair_assigned");
    const guestAssign = await guest.waitFor((m) => m.type === "pair_assigned");

    assert.equal(hostAssign.role, "pair");
    assert.equal(guestAssign.role, "pair");

    // Both report mutual UWB sighting.
    host.send({
      type: "pair_evidence",
      v: 1,
      roundId: hostAssign.roundId,
      phase: "confirm",
      selfToken: "tokHost",
      channels: [{ kind: "uwb", peerToken: "tokGuest", distanceM: 0.05, observedAtMs: Date.now() }],
    });
    guest.send({
      type: "pair_evidence",
      v: 1,
      roundId: guestAssign.roundId,
      phase: "confirm",
      selfToken: "tokGuest",
      channels: [{ kind: "uwb", peerToken: "tokHost", distanceM: 0.05, observedAtMs: Date.now() }],
    });

    const hostConfirm = await host.waitFor((m) => m.type === "pair_confirmed");
    const guestConfirm = await guest.waitFor((m) => m.type === "pair_confirmed");
    assert.equal(hostConfirm.partnerDisplayName, "Guest");
    assert.equal(guestConfirm.partnerDisplayName, "Host");

    host.close();
    guest.close();
  });
});
