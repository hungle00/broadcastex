# Broadcastex

A lightweight, self-hosted real-time messaging server built with Elixir, inspired by Pusher. Broadcastex enables applications to authenticate clients, subscribe to channels, and receive events over WebSockets.

## Overview

Broadcastex provides a self-hosted solution for real-time event delivery, powered by Elixir and OTP. It combines WebSocket communication, Mnesia persistence, and a dashboard for monitoring server insights.

## Features

- **WebSocket communication** — Persistent connections and real-time event delivery.
- **Channel-based broadcasting** — Publish events to subscribed clients.
- **Authentication** — Control access to the server and its resources.
- **Mnesia persistence** — Store data using Erlang's distributed database.
- **Insight dashboard** — Monitor server activity and real-time metrics.
- **Self-hosted** — Run and manage the service on your own infrastructure.

## How to Set Up

### Prerequisites

- [Elixir](https://elixir-lang.org/)
- Erlang/OTP

### Installation

```bash
git clone https://github.com/hungle00/broadcastex/
cd broadcastex
mix deps.get
```

### Run the server

```bash
mix run --no-halt
```

Configure the server settings, Mnesia storage, and dashboard access as needed for your environment.


