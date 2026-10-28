const assert = require("node:assert/strict");
const test = require("node:test");
const { BroadcastexClient } = require("./broadcastex.js");

class FakeWebSocket {
  static OPEN = 1;
  static instances = [];

  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.sent = [];
    FakeWebSocket.instances.push(this);
  }

  send(message) {
    this.sent.push(JSON.parse(message));
  }

  close() {
    this.readyState = 3;
    this.onclose?.({ code: 1000 });
  }

  open() {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen?.();
    this.receive({
      event: "broadcastex:connection_established",
      data: JSON.stringify({ socket_id: "123.456", activity_timeout: 120 })
    });
  }

  receive(message) {
    this.onmessage?.({ data: JSON.stringify(message) });
  }
}

async function connectClient(options = {}) {
  FakeWebSocket.instances = [];
  const client = new BroadcastexClient("ws://localhost:4000/app/test-key", {
    WebSocketImpl: FakeWebSocket,
    ...options
  });
  const connected = client.connect();
  const socket = FakeWebSocket.instances[0];
  socket.open();
  await connected;
  return { client, socket };
}

test("connects, subscribes to public channels, and dispatches events", async () => {
  const { client, socket } = await connectClient();
  const subscription = client.subscribe("public-chat");

  assert.deepEqual(socket.sent[0], {
    event: "broadcastex:subscribe",
    data: { channel: "public-chat" }
  });

  socket.receive({
    event: "broadcastex_internal:subscription_succeeded",
    channel: "public-chat"
  });
  const channel = await subscription;
  const received = [];
  channel.bind("chat-message", (data) => received.push(data));
  socket.receive({
    event: "chat-message",
    channel: "public-chat",
    data: { text: "hello" }
  });

  assert.deepEqual(received, [{ text: "hello" }]);
  client.disconnect();
});

test("authorizes presence, initializes members, and handles member changes", async () => {
  const authorizations = [];
  const { client, socket } = await connectClient({
    authorize: async (request) => {
      authorizations.push(request);
      return { auth: "test-key:signature" };
    }
  });
  const subscription = client.subscribe("presence-chat", {
    userId: "user-1",
    userInfo: { name: "Alice" }
  });
  await Promise.resolve();
  const sentData = socket.sent[0].data;

  assert.equal(sentData.channel, "presence-chat");
  assert.equal(sentData.auth, "test-key:signature");
  assert.deepEqual(JSON.parse(sentData.channel_data), {
    user_id: "user-1",
    user_info: { name: "Alice" }
  });
  assert.equal(authorizations[0].channelData, sentData.channel_data);

  socket.receive({
    event: "broadcastex_internal:subscription_succeeded",
    channel: "presence-chat",
    data: {
      presence: {
        count: 1,
        ids: ["user-2"],
        hash: { "user-2": { name: "Bob" } }
      }
    }
  });
  const channel = await subscription;
  const here = [];
  const joining = [];
  const leaving = [];
  channel.onPresence({
    here: (members) => here.push(members),
    joining: (member) => joining.push(member),
    leaving: (member) => leaving.push(member)
  });

  assert.deepEqual(here, [[{ user_id: "user-2", user_info: { name: "Bob" } }]]);

  socket.receive({
    event: "broadcastex_internal:member_added",
    channel: "presence-chat",
    data: { user_id: "user-3", user_info: { name: "Carol" } }
  });
  socket.receive({
    event: "broadcastex_internal:member_removed",
    channel: "presence-chat",
    data: { user_id: "user-2", user_info: { name: "Bob" } }
  });

  assert.deepEqual(joining, [{ user_id: "user-3", user_info: { name: "Carol" } }]);
  assert.deepEqual(leaving, [{ user_id: "user-2", user_info: { name: "Bob" } }]);
  assert.deepEqual(channel.memberList(), [
    { user_id: "user-3", user_info: { name: "Carol" } }
  ]);
  client.disconnect();
});
