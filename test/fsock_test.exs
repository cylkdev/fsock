defmodule FSockTest do
  use ExUnit.Case, async: false

  setup do
    room = Path.join(System.tmp_dir!(), "fsock-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(room) end)
    {:ok, room: room, quiet: [io_device: false]}
  end

  describe "join/2,3" do
    test "round-trip by name with no mailbox tuples", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)

      assert :ok = FSock.tell(alice, "bob", "hi bob")
      assert {:ok, {"alice", "hi bob"}} = FSock.recv(bob, 1_000)

      assert :ok = FSock.tell(bob, "alice", "hi alice")
      assert {:ok, {"bob", "hi alice"}} = FSock.recv(alice, 1_000)

      refute_received {:fsock, _, _}

      FSock.leave(alice)
      FSock.leave(bob)
    end

    test "creates the room directory if it does not exist", %{room: room} do
      refute File.exists?(room)

      {:ok, sess} = FSock.join(room, "alice")

      assert File.dir?(room)
      assert File.exists?(Path.join(room, "alice.sock"))

      FSock.leave(sess)
      refute File.exists?(Path.join(room, "alice.sock"))
    end

    test "tell/3 to a missing peer returns :enoent", %{room: room, quiet: quiet} do
      {:ok, sess} = FSock.join(room, "alice", quiet)
      assert {:error, :enoent} = FSock.tell(sess, "ghost", "anyone?")
      FSock.leave(sess)
    end

    test "second join with the same name returns :name_taken without disturbing the live owner",
         %{room: room, quiet: quiet} do
      {:ok, alice1} = FSock.join(room, "alice", quiet)

      assert {:error, :name_taken} = FSock.join(room, "alice", quiet)

      # alice1 still alive and reachable.
      assert Process.alive?(alice1)
      assert File.exists?(Path.join(room, "alice.sock"))

      {:ok, bob} = FSock.join(room, "bob", quiet)
      assert :ok = FSock.tell(bob, "alice", "still you?")
      assert {:ok, {"bob", "still you?"}} = FSock.recv(alice1, 1_000)

      FSock.leave(alice1)
      FSock.leave(bob)
    end

    test "rejoin after leaving (stale socket file present) succeeds", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      FSock.leave(alice)

      # Simulate uncleaned-up socket file from a crashed previous run.
      File.touch!(Path.join(room, "alice.sock"))

      assert {:ok, alice2} = FSock.join(room, "alice", quiet)
      assert Process.alive?(alice2)
      FSock.leave(alice2)
    end
  end

  describe "address/2 + tell/2" do
    test "address/2 sets default peer for tell/2", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)

      assert {:error, :no_default_peer} = FSock.tell(alice, "hey")

      :ok = FSock.address(alice, "bob")
      assert :ok = FSock.tell(alice, "hey bob")
      assert {:ok, {"alice", "hey bob"}} = FSock.recv(bob, 1_000)

      FSock.leave(alice)
      FSock.leave(bob)
    end

    test "address/2 can switch the default peer", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)
      {:ok, carol} = FSock.join(room, "carol", quiet)

      :ok = FSock.address(alice, "bob")
      :ok = FSock.tell(alice, "to bob")
      assert {:ok, {"alice", "to bob"}} = FSock.recv(bob, 1_000)

      :ok = FSock.address(alice, "carol")
      :ok = FSock.tell(alice, "to carol")
      assert {:ok, {"alice", "to carol"}} = FSock.recv(carol, 1_000)

      FSock.leave(alice)
      FSock.leave(bob)
      FSock.leave(carol)
    end

    test "address/2 can be cleared with nil", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      :ok = FSock.address(alice, "bob")
      :ok = FSock.address(alice, nil)

      assert {:error, :no_default_peer} = FSock.tell(alice, "anyone?")
      FSock.leave(alice)
    end

    test "address/2 with invalid name leaves existing default unchanged",
         %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)

      :ok = FSock.address(alice, "bob")
      assert {:error, :invalid_name} = FSock.address(alice, "../escape")

      :ok = FSock.tell(alice, "still works")
      assert {:ok, {"alice", "still works"}} = FSock.recv(bob, 1_000)

      FSock.leave(alice)
      FSock.leave(bob)
    end
  end

  describe "recv/2" do
    test "returns {:error, :timeout} when idle", %{room: room, quiet: quiet} do
      {:ok, sess} = FSock.join(room, "alice", quiet)

      t0 = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = FSock.recv(sess, 50)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed >= 45
      assert elapsed < 500

      FSock.leave(sess)
    end

    test "concurrent waiters are served FIFO", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)

      t1 = Task.async(fn -> FSock.recv(bob, 1_000) end)
      Process.sleep(20)
      t2 = Task.async(fn -> FSock.recv(bob, 1_000) end)
      Process.sleep(20)

      :ok = FSock.tell(alice, "bob", "first")
      :ok = FSock.tell(alice, "bob", "second")

      assert {:ok, {"alice", "first"}} = Task.await(t1, 2_000)
      assert {:ok, {"alice", "second"}} = Task.await(t2, 2_000)

      FSock.leave(alice)
      FSock.leave(bob)
    end
  end

  describe "print mode" do
    test "writes '<peer> » <msg>\\n' to :io_device when nobody is recv-ing", %{room: room} do
      {:ok, io} = StringIO.open("")

      {:ok, alice} = FSock.join(room, "alice", io_device: false)
      {:ok, bob} = FSock.join(room, "bob", io_device: io)

      :ok = FSock.tell(alice, "bob", "hi bob")

      Process.sleep(100)

      {_, output} = StringIO.contents(io)
      assert output == "alice » hi bob\n"

      FSock.leave(alice)
      FSock.leave(bob)
    end
  end

  describe "name validation" do
    test "rejects names containing /", %{room: room} do
      assert {:error, :invalid_name} = FSock.join(room, "../evil")
      refute File.exists?(Path.join(room, "../evil.sock"))
    end

    test "rejects empty name", %{room: room} do
      assert {:error, :invalid_name} = FSock.join(room, "")
    end
  end

  describe "backward compatibility" do
    test "start_link/1 with :subscriber delivers raw mailbox tuples", %{room: room} do
      File.mkdir_p!(room)
      a_path = Path.join(room, "a.sock")
      b_path = Path.join(room, "b.sock")

      {:ok, a} = FSock.start_link(path: a_path, subscriber: self())
      {:ok, b} = FSock.start_link(path: b_path, subscriber: self())

      assert :ok = FSock.tell(a, b_path, "ping")
      assert_receive {:fsock, ^a_path, "ping"}, 500

      assert :ok = FSock.tell(b, a_path, "pong")
      assert_receive {:fsock, ^b_path, "pong"}, 500

      FSock.stop(a)
      FSock.stop(b)
    end

    test "binding cleans up a stale socket file", %{room: room} do
      File.mkdir_p!(room)
      path = Path.join(room, "stale.sock")
      File.touch!(path)

      {:ok, pid} = FSock.start_link(path: path, subscriber: self())
      assert Process.alive?(pid)
      FSock.stop(pid)
    end
  end

  describe "observe/2,3" do
    test "observer receives a copy of every tell in the room", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)
      {:ok, charlie} = FSock.observe(room, "charlie", quiet)

      assert :ok = FSock.tell(alice, "bob", "hi bob")

      assert {:ok, {"alice", "hi bob"}} = FSock.recv(bob, timeout: 1_000)
      assert {:ok, {"alice", "hi bob"}} = FSock.recv(charlie, timeout: 1_000)

      FSock.leave(alice)
      FSock.leave(bob)
      FSock.leave(charlie)
    end

    test "every observer in the room receives a copy", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)
      {:ok, obs1} = FSock.observe(room, "logger1", quiet)
      {:ok, obs2} = FSock.observe(room, "logger2", quiet)

      assert :ok = FSock.tell(alice, "bob", "ping")

      assert {:ok, {"alice", "ping"}} = FSock.recv(bob, timeout: 1_000)
      assert {:ok, {"alice", "ping"}} = FSock.recv(obs1, timeout: 1_000)
      assert {:ok, {"alice", "ping"}} = FSock.recv(obs2, timeout: 1_000)

      FSock.leave(alice)
      FSock.leave(bob)
      FSock.leave(obs1)
      FSock.leave(obs2)
    end

    test "observer is not addressable as a peer by nickname", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, obs} = FSock.observe(room, "logger", quiet)

      assert {:error, :enoent} = FSock.tell(alice, "logger", "you there?")

      FSock.leave(alice)
      FSock.leave(obs)
    end

    test "leave/1 removes the observer socket file", %{room: room, quiet: quiet} do
      {:ok, obs} = FSock.observe(room, "logger", quiet)
      observer_path = Path.join([room, ".observers", "logger.sock"])
      assert File.exists?(observer_path)

      FSock.leave(obs)

      refute File.exists?(observer_path)
    end

    test "observer with :subscriber routes messages as {:fsock, peer, msg}",
         %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)
      {:ok, obs} = FSock.observe(room, "logger", Keyword.put(quiet, :subscriber, self()))

      assert :ok = FSock.tell(alice, "bob", "audit me")

      assert_receive {:fsock, "alice", "audit me"}, 1_000

      FSock.leave(alice)
      FSock.leave(bob)
      FSock.leave(obs)
    end
  end

  describe "shout/2" do
    test "every peer in the room receives one copy", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)
      {:ok, carol} = FSock.join(room, "carol", quiet)

      assert :ok = FSock.shout(alice, "hello room")

      assert {:ok, {"alice", "hello room"}} = FSock.recv(bob, timeout: 1_000)
      assert {:ok, {"alice", "hello room"}} = FSock.recv(carol, timeout: 1_000)

      assert {:error, :timeout} = FSock.recv(alice, timeout: 100)

      FSock.leave(alice)
      FSock.leave(bob)
      FSock.leave(carol)
    end

    test "observer receives one copy per shout, not one per peer", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)
      {:ok, carol} = FSock.join(room, "carol", quiet)
      {:ok, logger} = FSock.observe(room, "logger", quiet)

      assert :ok = FSock.shout(alice, "single copy please")

      assert {:ok, {"alice", "single copy please"}} =
               FSock.recv(logger, timeout: 1_000)

      assert {:error, :timeout} = FSock.recv(logger, timeout: 250)

      FSock.leave(alice)
      FSock.leave(bob)
      FSock.leave(carol)
      FSock.leave(logger)
    end

    test "shout in a room with no other peers returns :ok", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)

      assert :ok = FSock.shout(alice, "anyone here?")

      assert {:error, :timeout} = FSock.recv(alice, timeout: 100)

      FSock.leave(alice)
    end

    test "stale .sock file in the room does not break shout", %{room: room, quiet: quiet} do
      {:ok, alice} = FSock.join(room, "alice", quiet)
      {:ok, bob} = FSock.join(room, "bob", quiet)

      File.touch!(Path.join(room, "ghost.sock"))

      assert :ok = FSock.shout(alice, "still works")

      assert {:ok, {"alice", "still works"}} = FSock.recv(bob, timeout: 1_000)

      FSock.leave(alice)
      FSock.leave(bob)
    end
  end
end
