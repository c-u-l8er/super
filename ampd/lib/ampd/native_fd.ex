defmodule Ampd.NativeFd do
  @moduledoc """
  The one place a raw descriptor stops existing.

  Everything else in the runtime holds descriptors through OTP handles,
  which own and close themselves. Exactly one thing does not: a descriptor
  that arrives over `SCM_RIGHTS`. `unix(7)` defines that as `dup(2)` into
  *this* process's table, so it is this process's descriptor from the
  moment it lands, and nothing outside the BEAM can dispose of it — the
  sender closing its copy makes no difference, and a port program has its
  own descriptor table and cannot reach ours.

  Neither can Erlang. Measured, on OTP 28:

      :socket.open(fd, %{dup: false})   the handle IS fd
        :socket.close/1 → :ok           fd still open
      :socket.open(fd, %{dup: true})    the handle is a new fd
        :socket.close/1 → :ok           the new fd closed, fd still open

  OTP closes what OTP created. That is correct of it, and it leaves one
  descriptor per received descriptor with no owner in Erlang and no call
  that can free it. F.8.1 measured that residue and named it; this is the
  three syscalls that end it.

  ## Why `state/1` is here

  `dup(2)` does not copy `FD_CLOEXEC`. Adopting with `dup => true` is the
  only way to make OTP own and close its handle, and it produces an
  **inheritable** duplicate of a descriptor that arrived close-on-exec —
  silently undoing `[:cmsg_cloexec]`. So the flag has to be put back, and a
  claim about a descriptor's flags should be measured rather than reasoned
  about. `state/1` is how the tests measure it.
  """

  @on_load :load

  @doc false
  def load do
    path = :filename.join(:code.priv_dir(:ampd), ~c"ampd_fd_nif")

    # Never fail the module load. A runtime with no sink is refused where
    # that matters — `Ampd.Bridge` will not open a bridge without one —
    # and a module that would not load could not even say so.
    loaded = :erlang.load_nif(path, 0) == :ok
    :persistent_term.put({__MODULE__, :loaded}, loaded)
    :ok
  end

  @doc """
  Is the native sink loaded?

  Recorded at load rather than answered by a NIF stub: a stub that returns
  `false` is a *literal* `false` to the compiler, so every call site that
  checks it reads as dead code — and this is the one function whose whole
  job is to be true sometimes and false others.
  """
  def available?, do: :persistent_term.get({__MODULE__, :loaded}, false)

  @doc """
  `close(2)` a descriptor this process received and nothing owns.

  Returns `:ok`, or `{:error, errno}`. **Never retry it.** Linux releases
  the descriptor number before an error can be reported, so a second call
  can close a number another thread has since been given — `close(2)`
  NOTES says exactly this, and this is a 24-core SMP VM. An error means
  the number is gone regardless.

  **Any non-negative descriptor.** This refused anything below 3 on the
  reasoning that a received descriptor is never one of the VM's own — true
  of how the host spawns the runtime today, not of Linux, and not of a
  desktop session launching a GUI. A sink with an exception is not a sink.
  """
  def close_received(_fd), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Put back the `FD_CLOEXEC` that `dup(2)` dropped."
  def set_cloexec(_fd), do: :erlang.nif_error(:nif_not_loaded)

  @doc "`:closed` · `:cloexec` · `:inheritable` — three states, not two."
  def state(_fd), do: :erlang.nif_error(:nif_not_loaded)

  # ------------------------------------------------- the whole lifecycle
  #
  # Two functions, and between them every descriptor this runtime ever
  # extracts from ancillary data. There is no third exit.

  @doc """
  Adopt a received descriptor: OTP takes an owned duplicate, and the
  descriptor we were handed is closed.

      SCM_RIGHTS raw fd            close-on-exec, ours, owned by nothing
        :socket.open(fd, dup: true)  →  an OTP-owned duplicate
        set_cloexec/1                →  the flag dup(2) dropped, back
        close_received/1             →  the raw fd is gone
        ... later :socket.close/1    →  OTP closes what OTP created
                                        residue: none

  **`dup: true`, and F.8.1 had this backwards.** That brief chose
  `dup: false` on the reasoning that one descriptor with one owner beats
  two — and it is one descriptor, with *no* owner, because OTP will not
  close a descriptor it did not create. `dup: true` is the only setting
  under which the socket handle closes anything at all; the second
  descriptor is not waste, it is the one OTP can free.

  Stated plainly: between OTP's `dup(2)` and `set_cloexec/1` there is a
  window in which the duplicate is inheritable. Nothing on this VM can
  enter it — `erl_child_setup` closes every descriptor above 2 before
  `exec`, which F.8.1 measured — and `socket:open/2` offers no
  close-on-exec option, so the window is closed as tightly as the API
  allows rather than as tightly as one would like.
  """
  def adopt_socket(fd) when is_integer(fd) do
    case :socket.open(fd, %{dup: true}) do
      {:ok, sock} ->
        case confine(sock) do
          :ok ->
            discard(fd)
            {:ok, sock}

          :error ->
            # A duplicate we cannot confine is a descriptor that outlives
            # `exec`. Refuse the channel rather than serve it: both this
            # and the original are sunk, and the caller is told no.
            :socket.close(sock)
            discard(fd)
            :error
        end

      _ ->
        discard(fd)
        :error
    end
  end

  @doc """
  The sink. A descriptor that is surplus, rejected, or failed adoption
  ends here — the same call, so there is nothing to forget.

  Always `:ok` from the caller's side, and **total**. On Linux the number
  is released whatever `close(2)` reports, so there is no recovery to
  attempt; and a value that is not a descriptor at all has nothing to
  release. The layering is deliberate: `close_received/1` is strict and
  raises on a negative, this is the wrapper that cannot.

  It was not total, and the missing case was reachable. While the sink
  refused everything below 3, `discard(-1)` came back `{:error, 0}` and
  looked handled; removing that floor turned the same call into a
  `badarg` that killed the bridge — from `adopt_channel(-1, :agent, ...)`,
  which is a test in this suite and, more to the point, a call any code
  inside the runtime can make. The floor was masking a crash, which is
  its own argument for not having had one.
  """
  def discard(fd) when is_integer(fd) and fd >= 0 do
    _ = close_received(fd)
    :ok
  end

  def discard(_), do: :ok

  defp confine(sock) do
    with {:ok, fd} <- :socket.getopt(sock, :otp, :fd),
         :ok <- set_cloexec(fd) do
      :ok
    else
      _ -> :error
    end
  end
end
