(function (root) {
  "use strict";

  const HANDSHAKE_EVENT = "broadcastex:connection_established";
  const SUBSCRIBE_EVENT = "broadcastex:subscribe";
  const UNSUBSCRIBE_EVENT = "broadcastex:unsubscribe";
  const SUBSCRIPTION_SUCCEEDED_EVENT = "broadcastex_internal:subscription_succeeded";
  const MEMBER_ADDED_EVENT = "broadcastex_internal:member_added";
  const MEMBER_REMOVED_EVENT = "broadcastex_internal:member_removed";

  class EventEmitter {
    constructor() {
      this.listeners = new Map();
    }

    bind(event, callback) {
      if (typeof callback !== "function") {
        throw new TypeError("Event listener must be a function");
      }

      if (!this.listeners.has(event)) {
        this.listeners.set(event, new Set());
      }

      this.listeners.get(event).add(callback);
      return this;
    }

    unbind(event, callback) {
      if (callback) {
        this.listeners.get(event)?.delete(callback);
      } else {
        this.listeners.delete(event);
      }

      return this;
    }

    emit(event, data) {
      for (const callback of this.listeners.get(event) || []) {
        callback(data);
      }
    }
  }

  class BroadcastexChannel extends EventEmitter {
    constructor(client, name) {
      super();
      this.client = client;
      this.name = name;
      this.members = new Map();
      this.presenceInitialized = false;
      this.presenceCallbacks = null;
    }

    onPresence(callbacks = {}) {
      this.presenceCallbacks = callbacks;

      if (this.presenceInitialized && typeof callbacks.here === "function") {
        callbacks.here(this.memberList());
      }

      return this;
    }

    unsubscribe() {
      this.client.unsubscribe(this.name);
      return this;
    }

    receive(message) {
      const { event, data } = message;

      if (event === SUBSCRIPTION_SUCCEEDED_EVENT) {
        if (data?.presence) {
          const presence = data.presence;
          this.members = new Map(
            Object.entries(presence.hash || {}).map(([userId, userInfo]) => [
              userId,
              { user_id: userId, user_info: userInfo }
            ])
          );
          this.presenceInitialized = true;
          this.presenceCallbacks?.here?.(this.memberList());
        }

      } else if (event === MEMBER_ADDED_EVENT && data) {
        const member = { user_id: data.user_id, user_info: data.user_info };
        this.members.set(member.user_id, member);
        this.presenceCallbacks?.joining?.(member);
        this.emit("member_added", data);
      } else if (event === MEMBER_REMOVED_EVENT && data) {
        const member = {
          user_id: data.user_id,
          user_info: data.user_info ?? this.members.get(data.user_id)?.user_info
        };
        this.members.delete(member.user_id);
        this.presenceCallbacks?.leaving?.(member);
        this.emit("member_removed", data);
      }

      this.emit(event, data);
      this.emit("*", message);
    }

    memberList() {
      return Array.from(this.members.values());
    }
  }

  class BroadcastexClient extends EventEmitter {
    constructor(url, options = {}) {
      super();
      this.url = url;
      this.authorize = options.authorize;
      this.WebSocketImpl = options.WebSocketImpl || root.WebSocket;
      this.subscribeTimeout = options.subscribeTimeout || 10_000;
      this.socket = null;
      this.socketId = null;
      this.channels = new Map();
      this.pendingSubscriptions = new Map();
      this.connectPromise = null;
    }

    connect() {
      if (this.socket?.readyState === this.WebSocketImpl.OPEN) {
        return Promise.resolve(this);
      }

      if (this.connectPromise) {
        return this.connectPromise;
      }

      if (typeof this.WebSocketImpl !== "function") {
        return Promise.reject(new Error("WebSocket is not available in this environment"));
      }

      this.connectPromise = new Promise((resolve, reject) => {
        const socket = new this.WebSocketImpl(this.url);
        this.socket = socket;
        let settled = false;

        const fail = (error) => {
          if (!settled) {
            settled = true;
            reject(error);
          }
        };

        socket.onopen = () => this.emit("open");
        socket.onmessage = (event) => {
          try {
            const message = JSON.parse(event.data);

            if (message.event === HANDSHAKE_EVENT) {
              const details =
                typeof message.data === "string" ? JSON.parse(message.data) : message.data;
              if (typeof details?.socket_id !== "string") {
                throw new Error("Handshake did not contain a valid socket_id");
              }

              this.socketId = details.socket_id;
              if (!settled) {
                settled = true;
                resolve(this);
              }
              this.emit(HANDSHAKE_EVENT, details);
              return;
            }

            this.handleMessage(message);
          } catch (error) {
            this.emit("error", error);
            fail(error);
          }
        };
        socket.onerror = () => {
          const error = new Error("WebSocket connection failed");
          this.emit("error", error);
          fail(error);
        };
        socket.onclose = (event) => {
          const error = new Error(`WebSocket closed before handshake (code ${event.code})`);
          fail(error);
          for (const pending of this.pendingSubscriptions.values()) {
            clearTimeout(pending.timeout);
            pending.reject(new Error("WebSocket connection closed"));
          }
          this.pendingSubscriptions.clear();
          this.emit("close", event);
        };
      }).finally(() => {
        this.connectPromise = null;
      });

      return this.connectPromise;
    }

    async subscribe(channelName, options = {}) {
      if (!this.socketId || this.socket?.readyState !== this.WebSocketImpl.OPEN) {
        throw new Error("Connect to Broadcastex before subscribing");
      }

      const existing = this.channels.get(channelName);
      if (existing) {
        return existing;
      }

      const channel = new BroadcastexChannel(this, channelName);
      this.channels.set(channelName, channel);

      try {
        const data = { channel: channelName };
        const isPresence = channelName.startsWith("presence-");
        const isPrivate = channelName.startsWith("private-");

        if (isPresence) {
          if (typeof options.userId !== "string" || options.userId.length === 0) {
            throw new Error("A non-empty userId is required for presence channels");
          }

          data.channel_data = JSON.stringify({
            user_id: options.userId,
            user_info: options.userInfo || {}
          });
        }

        if (isPrivate || isPresence) {
          if (typeof this.authorize !== "function") {
            throw new Error("An authorize callback is required for private and presence channels");
          }

          const authorization = await this.authorize({
            socketId: this.socketId,
            channel: channelName,
            channelData: data.channel_data
          });

          if (typeof authorization?.auth !== "string") {
            throw new Error("The authorize callback must return an auth string");
          }

          data.auth = authorization.auth;
        }

        const subscribed = new Promise((resolve, reject) => {
          const timeout = setTimeout(() => {
            this.pendingSubscriptions.delete(channelName);
            reject(new Error(`Timed out subscribing to ${channelName}`));
          }, this.subscribeTimeout);

          this.pendingSubscriptions.set(channelName, {
            resolve: () => resolve(channel),
            reject,
            timeout
          });
        });

        this.socket.send(
          JSON.stringify({
            event: SUBSCRIBE_EVENT,
            data
          })
        );

        return await subscribed;
      } catch (error) {
        const pending = this.pendingSubscriptions.get(channelName);
        if (pending) {
          clearTimeout(pending.timeout);
          pending.reject(error);
          this.pendingSubscriptions.delete(channelName);
        }

        if (this.channels.get(channelName) === channel) {
          this.channels.delete(channelName);
        }
        throw error;
      }
    }

    unsubscribe(channelName) {
      const channel = this.channels.get(channelName);
      if (!channel) {
        return;
      }

      if (this.socket?.readyState === this.WebSocketImpl.OPEN) {
        this.socket.send(
          JSON.stringify({
            event: UNSUBSCRIBE_EVENT,
            data: { channel: channelName }
          })
        );
      }

      const pending = this.pendingSubscriptions.get(channelName);
      if (pending) {
        clearTimeout(pending.timeout);
        pending.reject(new Error(`Unsubscribed from ${channelName} before confirmation`));
        this.pendingSubscriptions.delete(channelName);
      }

      this.channels.delete(channelName);
    }

    disconnect() {
      this.socket?.close();
      this.socket = null;
      this.socketId = null;
      this.channels.clear();
    }

    handleMessage(message) {
      if (message.event === "broadcastex:error") {
        const error = new Error(message.data?.message || "Broadcastex subscription failed");
        for (const [channelName, pending] of this.pendingSubscriptions) {
          clearTimeout(pending.timeout);
          pending.reject(error);
          this.channels.delete(channelName);
        }
        this.pendingSubscriptions.clear();
        this.emit("error", error);
        return;
      }

      if (message.event === SUBSCRIPTION_SUCCEEDED_EVENT) {
        const pending = this.pendingSubscriptions.get(message.channel);
        if (pending) {
          clearTimeout(pending.timeout);
          this.pendingSubscriptions.delete(message.channel);
          pending.resolve();
        }
      }

      const channel = this.channels.get(message.channel);
      if (channel) {
        channel.receive(message);
      } else {
        this.emit(message.event, message);
        this.emit("*", message);
      }
    }
  }

  const Broadcastex = { BroadcastexClient, BroadcastexChannel };
  root.Broadcastex = Broadcastex;

  if (typeof module !== "undefined" && module.exports) {
    module.exports = Broadcastex;
  }
})(typeof globalThis === "undefined" ? this : globalThis);
