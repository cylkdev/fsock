defmodule FSock.Endpoint do
  @moduledoc """
  A UDP-over-Unix-domain-socket endpoint that turns a directory on disk into a
  tiny chat-style network.

  ## The mental model

  An "endpoint" is one participant. Each endpoint owns:

    * a **socket file** on disk (e.g. `chatroom/alice.sock`) — its address,
    * an **inbox** of messages it has received but not yet read,
    * an optional default `:peer` to send to (set via `address/2`).

  A "room" is just a directory. There is no server, no broker, and no
  membership list. "Joining" a room means creating your socket file inside
  the room directory; "leaving" means closing the socket, which deletes the
  file (see `terminate/2`). Datagrams travel directly from one socket file
  to another through the kernel.

  ## Joining a room and sending a message

  When Alice starts an endpoint with `room: "chatroom"` and
  `nickname: "alice"`, `init/1` opens a `:gen_udp` socket bound to the path
  `chatroom/alice.sock` (see `do_open/1`). The file appears on disk; Alice
  has "joined".

  When Alice calls `tell(server, "bob", "hi")`:

    1. `resolve_target/2` turns the bare name `"bob"` into the path
       `chatroom/bob.sock` by joining it with the room directory.
    2. `:gen_udp.send/4` writes the datagram to that socket path. The
       kernel delivers it to whichever process is bound there — no lookup,
       no handshake, no acknowledgement.
    3. Bob's endpoint receives `{:udp, _, {:local, "chatroom/alice.sock"},
       _, "hi"}` in `handle_info/2`. `decode_peer/2` strips the room
       prefix and the `.sock` suffix, leaving the bare name `"alice"`.
    4. The message is handed off to whichever consumer Bob has set up:
        * a process blocked on `recv/2` is replied to with
          `{:ok, {"alice", "hi"}}`,
        * else a `:subscriber` pid receives `{:fsock, "alice", "hi"}`,
        * else the line is printed to `:io_device` and the message is
          buffered in the inbox (capped at `:inbox_max`, oldest dropped
          first).

  ### Example

      # Alice opens her endpoint. A file appears at /tmp/chatroom/alice.sock.
      iex> {:ok, alice} = FSock.join("/tmp/chatroom", "alice")

      # Bob opens his. /tmp/chatroom/ now contains alice.sock and bob.sock.
      iex> {:ok, bob} = FSock.join("/tmp/chatroom", "bob")

      # Alice fires a datagram at /tmp/chatroom/bob.sock.
      iex> FSock.tell(alice, "bob", "hi")
      :ok

      # On Bob's terminal — handle_info/2 delivered the message to the
      # default consumer (his iex group leader).
      alice » hi

  ## Two endpoints chatting back and forth

  Alice and Bob each run their own `FSock.Endpoint` GenServer; the two are
  fully symmetrical. Alice's `tell/3` writes a datagram to
  `chatroom/bob.sock`; Bob's socket fires a `{:udp, ...}` message and the
  payload lands in his inbox or his pending `recv/2` waiter. When Bob
  replies with `tell(server, "alice", "hey")`, the same flow runs in
  reverse — Alice's socket receives the datagram, `decode_peer/2` recovers
  `"bob"`, and her consumer sees the message.

  There is no shared state between the two endpoints. The only thing they
  have in common is the room directory, which acts as a naming convention
  so they can address each other by short names instead of full paths.

  ### Example

      # Terminal 1 — Alice
      iex> {:ok, alice} = FSock.join("/tmp/chatroom", "alice")
      iex> FSock.tell(alice, "bob", "hello")
      :ok
      iex> FSock.recv(alice, timeout: 5_000)
      {:ok, {"bob", "hi back"}}

      # Terminal 2 — Bob
      iex> {:ok, bob} = FSock.join("/tmp/chatroom", "bob")
      iex> FSock.recv(bob, timeout: 5_000)
      {:ok, {"alice", "hello"}}
      iex> FSock.tell(bob, "alice", "hi back")
      :ok

  Notice that each side uses its own session reference (`alice`, `bob`) and
  its own socket file. The "conversation" is just two independent processes
  taking turns writing datagrams into each other's socket files.

  ## `address/2` — picking a default peer

  `address/2` is bookkeeping only; it does not touch the socket or send
  anything over the wire. It validates the given name against `@name_re`
  and stores it in the endpoint's state under `:peer`. Once set, the
  no-target `tell/2` uses that stored name — the
  `handle_call({:tell, message}, ...)` clause simply forwards to the
  targeted clause using `state.peer`. Calling `address(server, nil)`
  clears it.

  Think of `address/2` as "open a chat window with bob" in a chat client:
  nothing connects, nothing is reserved — you are only telling your
  endpoint "future messages I send without specifying a recipient should
  go to bob".

  ### Example

      iex> {:ok, alice} = FSock.join("/tmp/chatroom", "alice")

      # Pin bob as the default; tell/2 (no target arg) now goes to bob.
      iex> FSock.address(alice, "bob")
      :ok
      iex> FSock.tell(alice, "first message")
      :ok

      # Switch the default to carol — same tell/2 call, new recipient.
      iex> FSock.address(alice, "carol")
      :ok
      iex> FSock.tell(alice, "second message")
      :ok

      # Clear the default. tell/2 with no target now refuses.
      iex> FSock.address(alice, nil)
      :ok
      iex> FSock.tell(alice, "third message")
      {:error, :no_default_peer}

      # The 3-arg form is unaffected — it always names its target explicitly.
      iex> FSock.tell(alice, "bob", "still works")
      :ok

  ## Observers — passive copies of every tell

  An observer is an ordinary endpoint whose socket file lives in
  `<room>/.observers/<name>.sock` instead of `<room>/<name>.sock`. The
  `handle_call({:tell, target, message}, ...)` clause, after
  sending the datagram to the named target, calls
  `enumerate_observers/1` and sends an extra copy to every `*.sock`
  file under `.observers/`. The sender's own socket path is filtered
  out so observers do not receive echoes of their own tells.

  Observers run no special code: their `init/1` opens the same UDP
  socket, their `handle_info({:udp, ...})` dispatches via the same
  recv-waiter / `:subscriber` / inbox pipeline, and `decode_peer/2`
  strips the room prefix so the observer sees `"alice"`, not the full
  `<room>/alice.sock` path. Because their files live in a different
  directory, `resolve_target/2` cannot reach them by nickname — they
  are invisible to ordinary peer addressing.

  ## Shouting — room-wide fan-out

  `handle_call({:shout, message}, ...)` enumerates `<room>/*.sock` via
  `enumerate_peers/1` (skipping the sender's own path) and sends one
  datagram to each, then enumerates `<room>/.observers/*.sock` via
  `enumerate_observers/1` and sends one more copy to each observer.
  This is a *separate* code path from the per-peer tell handler —
  if `shout` simply iterated and called the tell handler N times,
  each iteration would re-trigger the observer-CC and observers would
  see the message N times. The dedicated handler walks observers
  exactly once.

  Per-recipient `:gen_udp.send/4` errors are swallowed so a single
  stale socket file cannot poison the fan-out. The reply is always
  `:ok`.

  ## Why it is shaped this way

    * **Local-only** — `:gen_udp` over `AF_UNIX` keeps everything on one
      machine and lets the filesystem (the room directory) act as the
      registry of who is reachable.
    * **Connectionless** — every `tell/3` is a fire-and-forget
      datagram, so endpoints can come and go without setting up or tearing
      down sessions.
    * **Stale-file aware** — `prepare_path/1` and `probe_path/1`
      distinguish a socket file whose owner is alive (`:name_taken`) from
      a leftover file from a crashed previous run (`:stale`, safe to
      remove and reuse).
  """

  use GenServer

  @name_re ~r/^[A-Za-z0-9_.-]+$/

  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    room = Keyword.get(opts, :room)

    if is_binary(room), do: File.mkdir_p!(room)

    case prepare_path(path) do
      :ok ->
        {gen_opts, opts} = Keyword.split(opts, [:name])
        opts = Keyword.put_new(opts, :io_device, Process.group_leader())
        GenServer.start_link(__MODULE__, opts, gen_opts)

      {:error, _} = err ->
        err
    end
  end

  def tell(server, message, opts \\ []) do
    GenServer.call(server, {:tell, message}, opts[:timeout] || 5000)
  end

  def tell(server, target, message, opts) do
    GenServer.call(server, {:tell, target, message}, opts[:timeout] || 5000)
  end

  def shout(server, message, opts \\ []) do
    GenServer.call(server, {:shout, message}, opts[:timeout] || 5000)
  end

  def address(server, name, opts \\ []) do
    GenServer.call(server, {:address, name}, opts[:timeout] || 5000)
  end

  def recv(server, opts) do
    timeout = opts[:timeout] || 5000

    call_timeout =
      case timeout do
        :infinity -> :infinity
        n when is_integer(n) and n >= 0 -> n + 50
      end

    GenServer.call(server, {:recv, timeout}, call_timeout)
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    room = Keyword.get(opts, :room)
    nickname = Keyword.get(opts, :nickname)
    peer = Keyword.get(opts, :peer)
    subscriber = Keyword.get(opts, :subscriber)
    io_device = Keyword.get(opts, :io_device, Process.group_leader())

    Process.flag(:trap_exit, true)

    case do_open(path) do
      {:ok, socket} ->
        state = %{
          socket: socket,
          path: path,
          room: room,
          nickname: nickname,
          peer: peer,
          subscriber: subscriber,
          io_device: io_device,
          waiters: :queue.new(),
          inbox: :queue.new(),
          inbox_max: 1024
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:tell, message}, from, state) do
    case state.peer do
      nil -> {:reply, {:error, :no_default_peer}, state}
      peer -> handle_call({:tell, peer, message}, from, state)
    end
  end

  def handle_call({:tell, target, message}, _from, state) do
    case resolve_target(target, state) do
      {:ok, peer_path} ->
        reply = :gen_udp.send(state.socket, {:local, peer_path}, 0, message)

        for obs_path <- enumerate_observers(state), obs_path != peer_path do
          _ = :gen_udp.send(state.socket, {:local, obs_path}, 0, message)
        end

        {:reply, reply, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:shout, message}, _from, state) do
    for peer_path <- enumerate_peers(state) do
      _ = :gen_udp.send(state.socket, {:local, peer_path}, 0, message)
    end

    for obs_path <- enumerate_observers(state) do
      _ = :gen_udp.send(state.socket, {:local, obs_path}, 0, message)
    end

    {:reply, :ok, state}
  end

  def handle_call({:address, name}, _from, state) do
    cond do
      is_nil(name) ->
        {:reply, :ok, %{state | peer: nil}}

      is_binary(name) and Regex.match?(@name_re, name) ->
        {:reply, :ok, %{state | peer: name}}

      true ->
        {:reply, {:error, :invalid_name}, state}
    end
  end

  def handle_call({:recv, timeout}, from, state) do
    case :queue.out(state.inbox) do
      {{:value, msg}, rest} ->
        {:reply, {:ok, msg}, %{state | inbox: rest}}

      {:empty, _} ->
        ref = make_ref()

        timer =
          case timeout do
            :infinity -> nil
            0 -> :immediate
            n -> Process.send_after(self(), {:recv_timeout, ref}, n)
          end

        case timer do
          :immediate ->
            {:reply, {:error, :timeout}, state}

          _ ->
            waiters = :queue.in({from, ref, timer}, state.waiters)
            {:noreply, %{state | waiters: waiters}}
        end
    end
  end

  @impl true
  def handle_info({:udp, _socket, addr, _port, data}, state) do
    peer = decode_peer(addr, state)

    case :queue.out(state.waiters) do
      {{:value, {from, _ref, timer}}, rest} ->
        cancel_timer(timer)
        GenServer.reply(from, {:ok, {peer, data}})
        {:noreply, %{state | waiters: rest}}

      {:empty, _} ->
        cond do
          is_pid(state.subscriber) ->
            Kernel.send(state.subscriber, {:fsock, peer, data})
            {:noreply, state}

          true ->
            if state.io_device, do: IO.puts(state.io_device, "#{data}")
            inbox = bounded_enqueue(state.inbox, {peer, data}, state.inbox_max)
            {:noreply, %{state | inbox: inbox}}
        end
    end
  end

  def handle_info({:recv_timeout, ref}, state) do
    {expired, kept} =
      state.waiters
      |> :queue.to_list()
      |> Enum.split_with(fn {_from, r, _timer} -> r == ref end)

    Enum.each(expired, fn {from, _r, _t} ->
      GenServer.reply(from, {:error, :timeout})
    end)

    {:noreply, %{state | waiters: :queue.from_list(kept)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(:queue.to_list(state.waiters), fn {from, _ref, timer} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, :closed})
    end)

    _ = :gen_udp.close(state.socket)
    _ = File.rm(state.path)
    :ok
  end

  defp prepare_path(path) do
    case File.stat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _} ->
        case probe_path(path) do
          :live ->
            {:error, :name_taken}

          :stale ->
            _ = File.rm(path)
            :ok

          :unknown ->
            {:error, :name_taken}
        end
    end
  end

  defp do_open(path) do
    :gen_udp.open(0, [
      :local,
      :binary,
      {:ifaddr, {:local, path}},
      {:active, true}
    ])
  end

  defp probe_path(path) do
    probe_socket_path =
      Path.join(System.tmp_dir!(), "fsock-probe-#{:erlang.unique_integer([:positive])}")

    case :gen_udp.open(0, [
           :local,
           :binary,
           {:ifaddr, {:local, probe_socket_path}}
         ]) do
      {:ok, sock} ->
        reply = :gen_udp.connect(sock, {:local, path}, 0)
        :gen_udp.close(sock)
        _ = File.rm(probe_socket_path)

        case reply do
          :ok -> :live
          {:error, _} -> :stale
        end

      {:error, _} ->
        :unknown
    end
  end

  defp resolve_target(target, %{room: nil}) when is_binary(target),
    do: {:ok, target}

  defp resolve_target(target, %{room: room}) when is_binary(target) do
    cond do
      String.contains?(target, "/") -> {:ok, target}
      Regex.match?(@name_re, target) -> {:ok, Path.join(room, target <> ".sock")}
      true -> {:error, :invalid_name}
    end
  end

  defp enumerate_observers(%{room: nil}), do: []

  defp enumerate_observers(%{room: room, path: own_path}) do
    dir = Path.join(room, ".observers")

    case File.ls(dir) do
      {:ok, entries} ->
        for entry <- entries,
            String.ends_with?(entry, ".sock"),
            path = Path.join(dir, entry),
            path != own_path,
            do: path

      {:error, _} ->
        []
    end
  end

  defp enumerate_peers(%{room: nil}), do: []

  defp enumerate_peers(%{room: room, path: own_path}) do
    case File.ls(room) do
      {:ok, entries} ->
        for entry <- entries,
            String.ends_with?(entry, ".sock"),
            path = Path.join(room, entry),
            path != own_path,
            do: path

      {:error, _} ->
        []
    end
  end

  defp decode_peer({:local, p}, state) when is_binary(p), do: name_for(p, state)
  defp decode_peer({:local, p}, state) when is_list(p), do: name_for(List.to_string(p), state)
  defp decode_peer(_, _), do: nil

  defp name_for(path, %{room: room}) when is_binary(room) do
    prefix = room <> "/"

    if String.starts_with?(path, prefix) do
      path
      |> String.replace_prefix(prefix, "")
      |> String.replace_suffix(".sock", "")
    else
      path
    end
  end

  defp name_for(path, _state), do: path

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp bounded_enqueue(queue, item, max) do
    queue = :queue.in(item, queue)

    if :queue.len(queue) > max do
      {{:value, _dropped}, trimmed} = :queue.out(queue)
      trimmed
    else
      queue
    end
  end
end
