defmodule FSock do
  @moduledoc """
  A friendly Unix-domain-socket chatroom: join a *room* under a *name*, and
  exchange messages with named peers.

  A **room** is a filesystem directory. Each participant binds an `AF_UNIX`
  socket inside that directory at `<name>.sock`. Sending to peer `"bob"`
  means delivering a datagram to `<room>/bob.sock`. The protocol is
  connectionless and symmetric: anyone can join under any unique name,
  either side can send first, and peers may live in different OS processes
  or BEAM nodes on the same host.

  Inbound messages, by default, **print themselves** to your iex shell
  (one line per datagram, formatted `"<peer> » <message>"`). No `flush/0`
  ritual, no mailbox pattern matching. If you want to consume messages
  programmatically, call `recv/1,2` to block for the next one, or pass a
  `:subscriber` pid to route raw `{:fsock, peer, msg}` tuples.

  ## Responsibilities

    - `join/2,3` enter a room as a name; bind the socket file and create
      the room directory if needed.
    - `address/2` set or change the default conversation partner used by
      `tell/2`.
    - `tell/2,3` deliver a binary message to a named peer (defaulting to
      whoever was set via `address/2`).
    - `recv/1,2` block synchronously for the next inbound message; return
      `{:ok, {peer, message}}` or `{:error, :timeout}`.
    - Print inbound messages to the user's shell when nobody is `recv`-ing
      and no programmatic subscriber is configured.
    - `leave/1` close the session and remove the bound socket file.

  ## Examples

      # Terminal 1
      iex> {:ok, sess} = FSock.join("/tmp/standup", "room_name")
      iex> FSock.tell(sess, "bob", "hi bob")
      :ok

      # Terminal 2 — alice's message just shows up, no flush()
      iex> {:ok, sess} = FSock.join("/tmp/standup", "bob")
      alice » hi bob
      iex> FSock.tell(sess, "room_name", "hi alice")
      :ok

  Or pin a default partner and use the 2-arg shorthand:

      iex> {:ok, sess} = FSock.join("/tmp/standup", "room_name")
      iex> :ok = FSock.address(sess, "bob")
      iex> FSock.tell(sess, "hi bob")
      :ok

  ## Observing a room

  A passive participant — a logger, a dashboard, a debug shell — can
  receive a copy of every message in the room without being addressable
  as a peer. Use `observe/2,3`:

      iex> {:ok, alice}  = FSock.join("/tmp/standup", "alice")
      iex> {:ok, bob}    = FSock.join("/tmp/standup", "bob")
      iex> {:ok, logger} = FSock.observe("/tmp/standup", "logger")

      iex> FSock.tell(alice, "bob", "ship it")
      :ok

      # bob (the named target) and logger (an observer) both receive a copy.
      iex> FSock.recv(bob,    timeout: 1_000)
      {:ok, {"alice", "ship it"}}
      iex> FSock.recv(logger, timeout: 1_000)
      {:ok, {"alice", "ship it"}}

  Observers see *who said what* but not *to whom* — UDP datagrams carry
  no application-level recipient field. They cannot be addressed by
  nickname from `tell/3`; their socket files live in a hidden
  `<room>/.observers/` subdirectory.

  ## Shouting to the whole room

  When you want every peer in the room to receive the same message,
  use `shout/2`. It walks `<room>/*.sock` (skipping the sender's own
  socket) and sends one datagram to each peer, then walks
  `<room>/.observers/` and sends one more copy to each observer:

      iex> {:ok, alice} = FSock.join("/tmp/standup", "alice")
      iex> {:ok, bob}   = FSock.join("/tmp/standup", "bob")
      iex> {:ok, carol} = FSock.join("/tmp/standup", "carol")

      iex> FSock.shout(alice, "stand-up in 5")
      :ok

      iex> FSock.recv(bob,   timeout: 1_000)
      {:ok, {"alice", "stand-up in 5"}}
      iex> FSock.recv(carol, timeout: 1_000)
      {:ok, {"alice", "stand-up in 5"}}

  `shout/2` is sender-side fan-out because `AF_UNIX SOCK_DGRAM` has no
  native multicast. Cost is O(peers + observers) per call, and there
  is no per-recipient ordering guarantee. Stale `*.sock` files left
  behind by crashed peers are tolerated — the per-recipient send error
  is swallowed and the rest of the fan-out proceeds.

  """

  # Abstraction Function:
  #   A session reference (pid or registered name) represents a logical
  #   participant in a room: the tuple {room_dir, nickname, peer_default,
  #   io_destination}, where room_dir is a filesystem directory shared with
  #   peers, nickname identifies this session inside that directory (its
  #   socket bound at room_dir/nickname.sock), peer_default is the optional
  #   conversation partner used by tell/2, and io_destination is where
  #   unrouted inbound messages are printed (the iex group leader, by
  #   default). The base case (a freshly joined session) has an empty recv
  #   waiter queue and no observed messages.
  #
  # Data Invariant:
  #   1. For every alive session, an AF_UNIX socket file exists at
  #      room_dir/nickname.sock, owned by exactly one Endpoint process.
  #   2. nickname matches /^[A-Za-z0-9_.-]+$/ -- it cannot contain "/"
  #      or escape the room.
  #   3. At most one alive session holds a given (room_dir, nickname) pair.
  #      Joining as a name already in use returns {:error, :name_taken}
  #      without disturbing the live owner.
  #   4. Inbound messages are dispatched in priority order: oldest recv
  #      waiter first, then :subscriber tuple delivery, then printing to
  #      :io_device plus inbox enqueue. Exactly one of these fires per
  #      inbound datagram.
  #   5. When a session terminates normally, its socket file is removed.

  @type session :: GenServer.server()

  @name_re ~r/^[A-Za-z0-9_.-]+$/

  @doc """
  Joins a chatroom under the given `name`, returning a session reference
  for later `tell/2,3`, `recv/1,2`, `address/2`, and `leave/1` calls.

  ## Parameters

    - `room` - `Path.t()`. Directory where socket files live; created if
      missing. All participants in a chatroom share this path.
    - `name` - `String.t()`. This session's nickname. Must match
      `~r/^[A-Za-z0-9_.-]+$/` -- no slashes, no `..`, no empty string.
      The bound socket file is `<room>/<name>.sock`.
    - `opts` - `keyword()`:
      - `:as` - `GenServer.name()`. Optional registered process name so
        you can refer to the session as e.g. `:alice` instead of a pid.
      - `:subscriber` - `pid()`. Programmatic mode: inbound messages are
        delivered as `{:fsock, peer_name, message}` to this pid. Disables
        the print-and-recv default.
      - `:io_device` - device or `false`. Override or disable the print
        sink. Defaults to the calling process's group leader.

  ## Returns

  `{:ok, session}` on success. The room directory exists, the socket file
  exists at `<room>/<name>.sock`, and the session satisfies the module's
  data invariant.

  Returns `{:error, :invalid_name}` if `name` is not a valid nickname.
  Returns `{:error, :name_taken}` if another live session already holds
  that name in that room (the existing owner's socket is **not**
  disturbed). Returns `{:error, {:open_failed, reason}}` for other bind
  failures.

  ## Examples

      {:ok, sess} = FSock.join("/tmp/standup", "room_name")
      {:ok, sess} = FSock.join("/tmp/standup", "room_name", as: :alice)

  """
  @spec join(Path.t(), String.t()) ::
          {:ok, pid()}
          | {:error, :invalid_name | :name_taken | {:open_failed, term()}}
  def join(room, name) when is_binary(room) and is_binary(name),
    do: do_join(room, name, [])

  @spec join(Path.t(), String.t(), keyword()) ::
          {:ok, pid()}
          | {:error, :invalid_name | :name_taken | {:open_failed, term()}}
  def join(room, name, opts) when is_binary(room) and is_binary(name) and is_list(opts),
    do: do_join(room, name, opts)

  defp do_join(room, name, opts) do
    if Regex.match?(@name_re, name) do
      path = Path.join(room, name <> ".sock")

      ep_opts =
        [path: path, room: room, nickname: name]
        |> maybe_put(:subscriber, Keyword.get(opts, :subscriber))
        |> maybe_put(:io_device, Keyword.get(opts, :io_device))
        |> maybe_put(:name, Keyword.get(opts, :as))

      case FSock.Endpoint.start_link(ep_opts) do
        {:ok, pid} -> {:ok, pid}
        {:error, :name_taken} -> {:error, :name_taken}
        {:error, {:name_taken, _path}} -> {:error, :name_taken}
        {:error, {:open_failed, _}} = err -> err
        other -> other
      end
    else
      {:error, :invalid_name}
    end
  end

  @doc """
  Joins a room as an observer: receives a copy of every tell issued
  inside that room, but is not addressable by name from regular peers.

  Observers bind their socket inside a reserved `<room>/.observers/`
  subdirectory. They are otherwise identical to ordinary participants —
  the same `recv/2`, `:subscriber`, and print-mode behaviours apply.

  ## Examples

      {:ok, obs} = FSock.observe("/tmp/standup", "logger")
      {:ok, {peer, msg}} = FSock.recv(obs, timeout: 5_000)

  """
  @spec observe(Path.t(), String.t()) ::
          {:ok, pid()}
          | {:error, :invalid_name | :name_taken | {:open_failed, term()}}
  def observe(room, name) when is_binary(room) and is_binary(name),
    do: do_observe(room, name, [])

  @spec observe(Path.t(), String.t(), keyword()) ::
          {:ok, pid()}
          | {:error, :invalid_name | :name_taken | {:open_failed, term()}}
  def observe(room, name, opts) when is_binary(room) and is_binary(name) and is_list(opts),
    do: do_observe(room, name, opts)

  defp do_observe(room, name, opts) do
    if Regex.match?(@name_re, name) do
      observers_dir = Path.join(room, ".observers")
      File.mkdir_p!(observers_dir)
      path = Path.join(observers_dir, name <> ".sock")

      ep_opts =
        [path: path, room: room, nickname: name]
        |> maybe_put(:subscriber, Keyword.get(opts, :subscriber))
        |> maybe_put(:io_device, Keyword.get(opts, :io_device))
        |> maybe_put(:name, Keyword.get(opts, :as))

      case FSock.Endpoint.start_link(ep_opts) do
        {:ok, pid} -> {:ok, pid}
        {:error, :name_taken} -> {:error, :name_taken}
        {:error, {:name_taken, _path}} -> {:error, :name_taken}
        {:error, {:open_failed, _}} = err -> err
        other -> other
      end
    else
      {:error, :invalid_name}
    end
  end

  @doc """
  Sets (or clears) the session's default conversation partner.

  After calling `address(sess, "bob")`, `tell(sess, msg)` (the 2-arity
  form) sends `msg` to `"bob"`. Pass `nil` to clear.

  Setting the address does **not** verify the peer is currently in the
  room -- resolution and reachability are checked at `tell/2,3` time.

  ## Returns

  `:ok` if `name` is a valid nickname (or `nil`). Returns
  `{:error, :invalid_name}` and leaves the existing default unchanged if
  `name` fails validation.

  ## Examples

      {:ok, sess} = FSock.join("/tmp/standup", "room_name")
      :ok = FSock.address(sess, "bob")
      :ok = FSock.tell(sess, "hi bob")

      :ok = FSock.address(sess, "carol")
      :ok = FSock.tell(sess, "hi carol")

      :ok = FSock.address(sess, nil)
      {:error, :no_default_peer} = FSock.tell(sess, "anyone?")

  """
  @spec address(session(), String.t() | nil) :: :ok | {:error, :invalid_name}
  def address(session, name) when is_binary(name) or is_nil(name),
    do: FSock.Endpoint.address(session, name)

  @doc """
  Sends `message` to the session's default peer (set via `address/2`).

  ## Returns

  `:ok` once the kernel has accepted the datagram. Returns
  `{:error, :no_default_peer}` if `address/2` was never called (or was
  cleared with `nil`). Returns `{:error, reason}` (e.g. `:enoent`) if
  the kernel rejects the send -- typically because the peer is not in
  the room.

  ## Examples

      {:ok, sess} = FSock.join("/tmp/room", "room_name")
      :ok = FSock.address(sess, "bob")
      :ok = FSock.tell(sess, "hello bob")

      {:ok, lonely} = FSock.join("/tmp/room", "carol")
      {:error, :no_default_peer} = FSock.tell(lonely, "anyone?")

  """
  @spec tell(session(), binary()) ::
          :ok | {:error, :no_default_peer | :inet.posix()}
  def tell(session, message) when is_binary(message),
    do: FSock.Endpoint.tell(session, message)

  @doc """
  Sends `message` to the named peer in the room.

  ## Parameters

    - `session` - `t:session/0`. Must satisfy the module's data invariant.
    - `target` - `String.t()`. Peer's nickname in the same room. Resolved
      to `<room>/<target>.sock`. If `target` contains a `/` it is treated
      as a raw filesystem path instead (escape hatch for path-mode use).
    - `message` - `binary()`. Payload; length is preserved end-to-end.

  ## Returns

  `:ok` once the kernel has accepted the datagram. Returns
  `{:error, :invalid_name}` if `target` is not a valid nickname (and not
  a path). Returns `{:error, :enoent}` if no peer is bound at the
  resolved path.

  ## Examples

      {:ok, sess} = FSock.join("/tmp/room", "room_name")
      :ok = FSock.tell(sess, "bob",   "hi bob")
      :ok = FSock.tell(sess, "carol", "hi carol")
      {:error, :enoent} = FSock.tell(sess, "ghost", "anyone?")

  """
  @spec tell(session(), String.t(), binary()) :: :ok | {:error, :invalid_name | :inet.posix()}
  def tell(session, target, message) when is_binary(target) and is_binary(message),
    do: FSock.Endpoint.tell(session, target, message, [])

  @spec tell(session(), String.t(), binary(), keyword()) :: :ok | {:error, :invalid_name | :inet.posix()}
  def tell(session, target, message, opts) when is_binary(target) and is_binary(message) do
    FSock.Endpoint.tell(session, target, message, opts)
  end

  @doc """
  Sends `message` to every peer in the same room (and every observer),
  in a single call. The sender does not receive its own shout.

  Internally this is sender-side fan-out — `AF_UNIX SOCK_DGRAM` has no
  native multicast — so cost is O(peers + observers). Per-recipient
  delivery errors (e.g. a stale socket file from a crashed peer) are
  swallowed; `shout/2` always returns `:ok`.

  ## Examples

      {:ok, sess} = FSock.join("/tmp/standup", "alice")
      :ok = FSock.shout(sess, "stand-up in 5")

  """
  @spec shout(session(), binary()) :: :ok
  def shout(session, message) when is_binary(message),
    do: FSock.Endpoint.shout(session, message)

  @doc """
  Synchronously waits for the next inbound message on this session.

  ## Parameters

    - `session` - `t:session/0`. Must satisfy the module's data invariant.
    - `timeout` - `non_neg_integer() | :infinity`. Milliseconds to wait
      before giving up. Default `:infinity`.

  ## Returns

  `{:ok, {peer, message}}` where `peer` is the sender's nickname (or raw
  path, if the sender bound outside the room) and `message` is the binary
  payload. Concurrent `recv/2` callers on the same session are served in
  FIFO order.

  Returns `{:error, :timeout}` if no message arrives in time. Returns
  `{:error, :closed}` to in-flight callers when the session is torn down
  by `leave/1`.

  Calling `recv/2` takes priority over the default print behaviour: while
  a caller is waiting, inbound messages are returned to that caller and
  not printed to the shell.

  ## Examples

      {:ok, sess} = FSock.join("/tmp/room", "room_name")
      {:ok, {"bob", "hi alice"}} = FSock.recv(sess, 5_000)
      {:error, :timeout} = FSock.recv(sess, 50)

  """
  @spec recv(session(), keyword()) :: {:ok, {String.t() | nil, binary()}} | {:error, :timeout | :closed}
  def recv(session, opts) do
    FSock.Endpoint.recv(session, opts)
  end

  @doc """
  Leaves the room: stops the session and removes its socket file.

  ## Returns

  `:ok` once the session has terminated and its socket file at
  `<room>/<name>.sock` has been removed. The path is then free to be
  re-joined.

  Any in-flight `recv/2` callers receive `{:error, :closed}`.

  Exits the caller with `:noproc` if `session` is not running.

  ## Examples

      {:ok, sess} = FSock.join("/tmp/room", "room_name")
      :ok = FSock.leave(sess)

  """
  @spec leave(session()) :: :ok
  def leave(session), do: GenServer.stop(session)

  @doc """
  OTP-level entry point: starts an endpoint at an explicit `:path`.

  Most callers should use `join/2,3` instead. `start_link/1` is the
  underlying primitive and is appropriate for tests and supervisor
  children that want to bypass name resolution.

  ## Options

    - `:path` (required) - `Path.t()`. Filesystem path at which to bind.
    - `:name` - `GenServer.name()`. Optional registered process name.
    - `:subscriber` - `pid()`. Optional pid to receive
      `{:fsock, peer, message}` tuples; disables the default print mode.
    - `:room`, `:nickname`, `:peer` - advanced; usually set by `join/2,3`.

  ## Returns

  `{:ok, pid}` on success. `{:error, :name_taken}` if the path is held
  by another live session. `{:error, {:open_failed, reason}}` for other
  bind failures.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: FSock.Endpoint.start_link(opts)

  @doc """
  Stops the session and removes its bound socket file. Alias for `leave/1`.
  """
  @spec stop(session()) :: :ok
  def stop(session), do: GenServer.stop(session)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
