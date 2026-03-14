import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import test from "node:test";

import {
  InviteReader,
  KEY_PACKAGE_KIND,
  KEY_PACKAGE_RELAY_LIST_KIND,
  GROUP_EVENT_KIND,
  WELCOME_EVENT_KIND,
  MarmotClient,
  KeyPackageStore,
  KeyValueGroupStateBackend,
  createKeyPackageRelayListEvent,
  deserializeApplicationData,
  extractMarmotGroupData,
  getKeyPackageRelayList,
} from "../../marmot-ts/dist/index.js";
import { PrivateKeyAccount } from "../../marmot-ts/node_modules/applesauce-accounts/dist/accounts/index.js";

const GIFT_WRAP_KIND = 1059;

const relayPort =
  process.env.PARRHESIA_MARMOT_E2E_RELAY_PORT ??
  process.env.PARRHESIA_E2E_RELAY_PORT ??
  "4051";
const relayHttpBase = `http://127.0.0.1:${relayPort}`;
const relayHttpUrl = `${relayHttpBase}/relay`;
const relayWsUrl = relayHttpUrl.replace("http://", "ws://");

class MemoryBackend {
  #map = new Map();

  async getItem(key) {
    return this.#map.get(key) ?? null;
  }

  async setItem(key, value) {
    this.#map.set(key, value);
    return value;
  }

  async removeItem(key) {
    this.#map.delete(key);
  }

  async clear() {
    this.#map.clear();
  }

  async keys() {
    return Array.from(this.#map.keys());
  }
}

class RelayNetwork {
  constructor(relayWs, relayHttp) {
    this.relayWs = relayWs;
    this.relayHttp = relayHttp;
  }

  async publish(relays, event) {
    const responses = await Promise.all(
      relays.map(async (relay) => {
        const frame = await publishEvent(relay, event);
        return [relay, { from: relay, ok: Boolean(frame[2]), message: frame[3] }];
      }),
    );

    return Object.fromEntries(responses);
  }

  async request(relays, filters) {
    const filtersArray = Array.isArray(filters) ? filters : [filters];

    const eventsById = new Map();

    for (const relay of relays) {
      const events = await requestEvents(relay, filtersArray);
      for (const event of events) {
        eventsById.set(event.id, event);
      }
    }

    return Array.from(eventsById.values());
  }

  subscription(relays, filters) {
    return {
      subscribe: (observer) => {
        let unsubscribed = false;

        void this.request(relays, filters)
          .then((events) => {
            for (const event of events) {
              if (unsubscribed) {
                return;
              }

              observer.next?.(event);
            }

            if (!unsubscribed) {
              observer.complete?.();
            }
          })
          .catch((error) => {
            if (!unsubscribed) {
              observer.error?.(error);
            }
          });

        return {
          unsubscribe: () => {
            unsubscribed = true;
          },
        };
      },
    };
  }

  async getUserInboxRelays(pubkey) {
    const relayListEvents = await this.request([this.relayWs], [
      { kinds: [KEY_PACKAGE_RELAY_LIST_KIND], authors: [pubkey], limit: 1 },
    ]);

    if (relayListEvents.length === 0) {
      return [this.relayWs];
    }

    const relays = getKeyPackageRelayList(relayListEvents[0]);
    return relays.length > 0 ? relays : [this.relayWs];
  }
}

function createClient(account, network) {
  return new MarmotClient({
    signer: account.signer,
    network,
    keyPackageStore: new KeyPackageStore(new MemoryBackend()),
    groupStateBackend: new KeyValueGroupStateBackend(new MemoryBackend()),
  });
}

function computeEventId(event) {
  const payload = [
    0,
    event.pubkey,
    event.created_at,
    event.kind,
    event.tags,
    event.content,
  ];

  return createHash("sha256").update(JSON.stringify(payload)).digest("hex");
}

function bytesToHex(bytes) {
  return Buffer.from(bytes).toString("hex");
}

function unixNow() {
  return Math.floor(Date.now() / 1000);
}

function randomSubId(prefix) {
  return `${prefix}-${randomUUID()}`;
}

async function openRelay(relayUrl, timeoutMs = 5_000) {
  const ws = new WebSocket(relayUrl);

  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`WebSocket open timeout for ${relayUrl}`));
    }, timeoutMs);

    ws.addEventListener(
      "open",
      () => {
        clearTimeout(timeout);
        resolve();
      },
      { once: true },
    );

    ws.addEventListener(
      "error",
      (error) => {
        clearTimeout(timeout);
        reject(error.error ?? error);
      },
      { once: true },
    );
  });

  const queue = [];
  let waiter = null;

  ws.addEventListener("message", (message) => {
    let frame;

    try {
      frame = JSON.parse(String(message.data));
    } catch {
      return;
    }

    if (waiter) {
      const activeWaiter = waiter;
      waiter = null;
      activeWaiter.resolve(frame);
    } else {
      queue.push(frame);
    }
  });

  ws.addEventListener("close", () => {
    if (waiter) {
      const activeWaiter = waiter;
      waiter = null;
      activeWaiter.reject(new Error(`WebSocket closed for ${relayUrl}`));
    }
  });

  return {
    send(frame) {
      ws.send(JSON.stringify(frame));
    },

    nextFrame(timeoutMs = 5_000) {
      if (queue.length > 0) {
        return Promise.resolve(queue.shift());
      }

      if (waiter) {
        return Promise.reject(new Error("Only one pending frame wait is supported"));
      }

      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          if (waiter) {
            waiter = null;
          }
          reject(new Error(`Timed out waiting for relay frame from ${relayUrl}`));
        }, timeoutMs);

        waiter = {
          resolve: (frame) => {
            clearTimeout(timeout);
            resolve(frame);
          },
          reject: (error) => {
            clearTimeout(timeout);
            reject(error);
          },
        };
      });
    },

    async close() {
      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
        ws.close();
      }
    },
  };
}

async function publishEvent(relayUrl, event, timeoutMs = 5_000) {
  const relay = await openRelay(relayUrl, timeoutMs);

  try {
    relay.send(["EVENT", event]);

    while (true) {
      const frame = await relay.nextFrame(timeoutMs);
      if (Array.isArray(frame) && frame[0] === "OK" && frame[1] === event.id) {
        return frame;
      }
    }
  } finally {
    await relay.close();
  }
}

async function requestEvents(relayUrl, filters, timeoutMs = 5_000) {
  const relay = await openRelay(relayUrl, timeoutMs);
  const subscriptionId = randomSubId("req");
  const events = [];

  try {
    relay.send(["REQ", subscriptionId, ...filters]);

    while (true) {
      const frame = await relay.nextFrame(timeoutMs);
      if (!Array.isArray(frame)) {
        continue;
      }

      const [type, subId, payload] = frame;

      if (type === "EVENT" && subId === subscriptionId) {
        events.push(payload);
      }

      if (type === "EOSE" && subId === subscriptionId) {
        break;
      }

      if (type === "CLOSED" && subId === subscriptionId) {
        throw new Error(`relay closed request ${subscriptionId}: ${payload}`);
      }
    }

    relay.send(["CLOSE", subscriptionId]);
    return events;
  } finally {
    await relay.close();
  }
}

async function requestGiftWrapsWithAuth({ relayUrl, relayHttpUrl, signer, recipientPubkey }) {
  const relay = await openRelay(relayUrl, 5_000);
  const probeSubId = randomSubId("auth-probe");

  try {
    relay.send(["REQ", probeSubId, { kinds: [GIFT_WRAP_KIND], "#p": [recipientPubkey], limit: 1 }]);

    let challenge = null;

    for (;;) {
      const frame = await relay.nextFrame(5_000);
      if (!Array.isArray(frame)) {
        continue;
      }

      if (frame[0] === "AUTH" && typeof frame[1] === "string") {
        challenge = frame[1];
      }

      if (frame[0] === "CLOSED" && frame[1] === probeSubId) {
        break;
      }
    }

    assert.ok(challenge, "relay should provide an AUTH challenge for restricted giftwrap queries");

    const authEvent = await signer.signEvent({
      kind: 22_242,
      created_at: unixNow(),
      tags: [
        ["challenge", challenge],
        ["relay", relayUrl],
      ],
      content: "",
    });

    relay.send(["AUTH", authEvent]);

    for (;;) {
      const frame = await relay.nextFrame(5_000);
      if (!Array.isArray(frame)) {
        continue;
      }

      if (frame[0] === "OK" && frame[1] === authEvent.id) {
        assert.equal(frame[2], true, `auth rejected: ${frame[3] ?? "unknown error"}`);
        break;
      }
    }

    const subscriptionId = randomSubId("giftwrap");
    const giftWraps = [];

    relay.send([
      "REQ",
      subscriptionId,
      { kinds: [GIFT_WRAP_KIND], "#p": [recipientPubkey], limit: 20 },
    ]);

    for (;;) {
      const frame = await relay.nextFrame(5_000);
      if (!Array.isArray(frame)) {
        continue;
      }

      const [type, subId, payload] = frame;

      if (type === "EVENT" && subId === subscriptionId) {
        giftWraps.push(payload);
      }

      if (type === "EOSE" && subId === subscriptionId) {
        break;
      }

      if (type === "CLOSED" && subId === subscriptionId) {
        throw new Error(`giftwrap request closed unexpectedly: ${payload}`);
      }
    }

    relay.send(["CLOSE", subscriptionId]);
    return giftWraps;
  } finally {
    await relay.close();
  }
}

test("relay returns NIP-11 metadata and advertises Marmot support", async () => {
  const response = await fetch(relayHttpUrl, {
    headers: { Accept: "application/nostr+json" },
  });

  assert.equal(response.status, 200);

  const body = await response.json();
  assert.equal(body.name, "Parrhesia");
  assert.ok(body.supported_nips.includes(59));
  assert.ok(body.supported_nips.includes(77));
});

test("key package create + rotate works against relay storage", async () => {
  const account = PrivateKeyAccount.generateNew();
  const pubkey = await account.signer.getPublicKey();
  const network = new RelayNetwork(relayWsUrl, relayHttpUrl);
  const client = createClient(account, network);

  const relayListEvent = await account.signer.signEvent(
    createKeyPackageRelayListEvent({
      pubkey,
      relays: [relayWsUrl],
      client: "parrhesia-marmot-e2e",
    }),
  );

  await network.publish([relayWsUrl], relayListEvent);

  const keyPackage = await client.keyPackages.create({
    relays: [relayWsUrl],
    client: "parrhesia-marmot-e2e",
  });

  const keyPackageRef = bytesToHex(keyPackage.keyPackageRef);

  const keyPackageEvents = await network.request([relayWsUrl], [
    { kinds: [KEY_PACKAGE_KIND], authors: [pubkey], limit: 10 },
  ]);

  assert.ok(keyPackageEvents.length >= 1);

  const matchingByRef = await network.request([relayWsUrl], [
    { kinds: [KEY_PACKAGE_KIND], "#i": [keyPackageRef], limit: 10 },
  ]);

  assert.ok(matchingByRef.length >= 1);

  await client.keyPackages.rotate(keyPackage.keyPackageRef, { relays: [relayWsUrl] });

  const afterRotateOldRef = await network.request([relayWsUrl], [
    { kinds: [KEY_PACKAGE_KIND], "#i": [keyPackageRef], limit: 10 },
  ]);

  assert.equal(afterRotateOldRef.length, 0);


});

test("kind 445 requests without #h are rejected by relay policy", async () => {
  const relay = await openRelay(relayWsUrl, 5_000);

  try {
    const subscriptionId = randomSubId("missing-h");
    relay.send(["REQ", subscriptionId, { kinds: [GROUP_EVENT_KIND], limit: 5 }]);

    for (;;) {
      const frame = await relay.nextFrame(5_000);
      if (!Array.isArray(frame)) {
        continue;
      }

      if (frame[0] === "CLOSED" && frame[1] === subscriptionId) {
        assert.match(String(frame[2]), /kind 445 queries must include a #h tag/);
        break;
      }
    }
  } finally {
    await relay.close();
  }
});

test("admin invites user, user joins, and message round-trip decrypts", async () => {
  const network = new RelayNetwork(relayWsUrl, relayHttpUrl);

  const adminAccount = PrivateKeyAccount.generateNew();
  const inviteeAccount = PrivateKeyAccount.generateNew();

  const adminPubkey = await adminAccount.signer.getPublicKey();
  const inviteePubkey = await inviteeAccount.signer.getPublicKey();

  const adminClient = createClient(adminAccount, network);
  const inviteeClient = createClient(inviteeAccount, network);

  const adminRelayList = await adminAccount.signer.signEvent(
    createKeyPackageRelayListEvent({
      pubkey: adminPubkey,
      relays: [relayWsUrl],
      client: "parrhesia-marmot-e2e",
    }),
  );

  const inviteeRelayList = await inviteeAccount.signer.signEvent(
    createKeyPackageRelayListEvent({
      pubkey: inviteePubkey,
      relays: [relayWsUrl],
      client: "parrhesia-marmot-e2e",
    }),
  );

  await network.publish([relayWsUrl], adminRelayList);
  await network.publish([relayWsUrl], inviteeRelayList);

  await inviteeClient.keyPackages.create({
    relays: [relayWsUrl],
    client: "parrhesia-marmot-e2e",
  });

  const adminGroup = await adminClient.createGroup(`Parrhesia Group ${randomUUID()}`, {
    relays: [relayWsUrl],
    adminPubkeys: [adminPubkey],
  });

  const inviteeKeyPackageEvents = await network.request([relayWsUrl], [
    { kinds: [KEY_PACKAGE_KIND], authors: [inviteePubkey], limit: 1 },
  ]);

  assert.equal(inviteeKeyPackageEvents.length, 1);

  await adminGroup.inviteByKeyPackageEvent(inviteeKeyPackageEvents[0]);

  const marmotGroupData = extractMarmotGroupData(adminGroup.state);
  assert.ok(marmotGroupData, "group should include Marmot extension data");

  const nostrGroupId = bytesToHex(marmotGroupData.nostrGroupId);

  const commitEvents = await network.request([relayWsUrl], [
    { kinds: [GROUP_EVENT_KIND], "#h": [nostrGroupId], limit: 10 },
  ]);
  assert.ok(commitEvents.length >= 1);

  const giftWraps = await requestGiftWrapsWithAuth({
    relayUrl: relayWsUrl,
    relayHttpUrl,
    signer: inviteeAccount.signer,
    recipientPubkey: inviteePubkey,
  });

  assert.equal(giftWraps.length, 1);

  const inviteReader = new InviteReader({
    signer: inviteeAccount.signer,
    store: {
      received: new MemoryBackend(),
      unread: new MemoryBackend(),
      seen: new MemoryBackend(),
    },
  });

  await inviteReader.ingestEvents(giftWraps);
  const invites = await inviteReader.decryptGiftWraps();

  assert.equal(invites.length, 1);
  assert.equal(invites[0].kind, WELCOME_EVENT_KIND);

  const { group: inviteeGroup } = await inviteeClient.joinGroupFromWelcome({
    welcomeRumor: invites[0],
  });

  const messageRumor = {
    kind: 9,
    pubkey: inviteePubkey,
    created_at: unixNow(),
    tags: [],
    content: `hello-from-invitee-${randomUUID()}`,
  };
  messageRumor.id = computeEventId(messageRumor);

  await inviteeGroup.sendApplicationRumor(messageRumor);

  const groupEventsAfterMessage = await network.request([relayWsUrl], [
    { kinds: [GROUP_EVENT_KIND], "#h": [nostrGroupId], limit: 50 },
  ]);

  const decryptedMessages = [];

  for await (const result of adminGroup.ingest(groupEventsAfterMessage)) {
    if (result.kind === "processed" && result.result.kind === "applicationMessage") {
      decryptedMessages.push(deserializeApplicationData(result.result.message));
    }
  }

  assert.ok(
    decryptedMessages.some((rumor) => rumor.content === messageRumor.content),
    "admin should decrypt invitee application message",
  );
});
