defmodule Ampd.T28AdoptTest do
  @moduledoc """
  T28 · L11 — a received socket is adopted on macOS, and only a local stream (`superlane/t28/TASK.md` item 7). Scored
  on Linux with real sockets: the Darwin options, `local_stream?/1` and the Darwin `adopt_check/2`. The Mac's half
  (a descriptor received as a right is adopted there) is MP2.
  """
  use ExUnit.Case, async: false
  alias Ampd.NativeFd

  test "L11 · the Darwin options name the local domain and the stream type; Linux's are unchanged" do
    assert NativeFd.adopt_opts({:unix, :darwin}) == %{dup: true, domain: :local, type: :stream}
    assert NativeFd.adopt_opts({:unix, :linux}) == %{dup: true}
  end

  test "L11 · a local stream end is accepted; an inet TCP socket and a local datagram socket are refused" do
    {a, b} = Ampd.Transport.socketpair(:stream)
    {:ok, tcp} = :socket.open(:inet, :stream, :tcp)
    {:ok, dgram} = :socket.open(:local, :dgram)
    assert NativeFd.local_stream?(a)
    refute NativeFd.local_stream?(tcp)
    refute NativeFd.local_stream?(dgram)
    assert NativeFd.adopt_check(a, {:unix, :darwin}) == :ok
    assert NativeFd.adopt_check(tcp, {:unix, :darwin}) == :error
    assert NativeFd.adopt_check(dgram, {:unix, :darwin}) == :error
    assert NativeFd.adopt_check(tcp, {:unix, :linux}) == :ok
    Enum.each([a, b, tcp, dgram], &:socket.close/1)
  end
end

defmodule Ampd.T28WireReaderTest do
  @moduledoc """
  T28 · L12 — an untrusted peer's rights never stay in the runtime (C9; `superlane/t28/TASK.md` revision 4). On macOS,
  or with `:ampd, :untrusted_rights_reader` forcing it (as here, on Linux), `Wire.reader_for/2` reads with `recvmsg`
  and a control buffer: frames without rights read as `Wire.reader/2` reads them; a frame that brought rights has them
  sunk and the channel ends. On the Linux default the reader is `Wire.reader/2`, whose text is the base's.
  """
  use ExUnit.Case, async: false
  alias Ampd.Transport.Wire

  # Wire.reader/2's text at b497c345 (lines 139-167, 864 B), measured before any T28 code.
  @base_reader "17544b50e36ef2793b0c02c7bbf3feb62c8d8a2aab6757fe6cc9d6ac4295d9eb"

  setup do
    prev = Application.fetch_env(:ampd, :untrusted_rights_reader)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:ampd, :untrusted_rights_reader, v)
        :error -> Application.delete_env(:ampd, :untrusted_rights_reader)
      end
    end)

    :ok
  end

  defp frame(b), do: <<byte_size(b)::big-32>> <> b
  defp beam_fds, do: length(File.ls!("/proc/self/fd"))

  defp rights(socks) do
    data = for s <- socks, into: <<>>, do: (fn {:ok, fd} -> <<fd::native-32>> end).(:socket.getopt(s, {:otp, :fd}))
    [%{level: :socket, type: :rights, data: data}]
  end

  test "L12 · forced, frames without rights are read as Wire.reader reads them" do
    Application.put_env(:ampd, :untrusted_rights_reader, true)
    {a, b} = Ampd.Transport.socketpair(:stream)
    me = self()
    pid = spawn(fn -> Wire.reader_for(a, me) end)
    :ok = :socket.send(b, frame("one") <> frame("") <> frame("two"))
    assert_receive {:frame, "one"}, 2_000
    assert_receive {:frame, "two"}, 2_000
    Process.exit(pid, :kill)
    Enum.each([a, b], &:socket.close/1)
  end

  test "L12 · forced, a frame that brings rights has them sunk, and the channel ends" do
    Application.put_env(:ampd, :untrusted_rights_reader, true)
    {a, b} = Ampd.Transport.socketpair(:stream)
    {x, y} = Ampd.Transport.socketpair(:stream)
    me = self()
    before = beam_fds()
    pid = spawn(fn -> Wire.reader_for(a, me) end)
    :ok = :socket.sendmsg(b, %{iov: [frame("rights from an agent")], ctrl: rights([y, y, y])})
    assert_receive :closed, 2_000
    refute_received {:frame, _}
    Process.sleep(50)
    assert beam_fds() <= before, "an agent's rights stayed: #{beam_fds() - before} descriptors"
    Process.exit(pid, :kill)
    Enum.each([a, b, x, y], &:socket.close/1)
  end

  test "L12 · on the Linux default the reader is Wire.reader/2, and its text is the base's" do
    Application.delete_env(:ampd, :untrusted_rights_reader)
    refute Wire.sinks_rights?(), "the Linux default takes the sinking reader"
    lines = File.read!("lib/ampd/transport.ex") |> String.split("\n")
    i = Enum.find_index(lines, &String.starts_with?(&1, "    def reader(sock, owner) do"))
    j = i + 1 + Enum.find_index(Enum.drop(lines, i + 1), &(&1 == "    end"))
    text = lines |> Enum.slice(i..j) |> Enum.join("\n")
    assert Base.encode16(:crypto.hash(:sha256, text), case: :lower) == @base_reader, "Wire.reader/2's text changed"
  end
end
