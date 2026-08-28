/* The receiver owns what it receives.
 *
 * `SCM_RIGHTS` is defined as `dup(2)` into the *receiving* process's
 * descriptor table (unix(7)). So a descriptor that arrives here is this
 * process's descriptor, and nothing outside this process can dispose of
 * it: not the sender closing its copy, not a port program with its own
 * table, not the runtime handing the number back.
 *
 * And `socket:close/1` will not do it either. Measured on OTP 28:
 *
 *     :socket.open(fd, %{dup: false})  →  handle IS fd
 *       :socket.close/1  →  :ok        →  fd still open
 *     :socket.open(fd, %{dup: true})   →  handle is a NEW fd
 *       :socket.close/1  →  :ok        →  the new fd closed, fd still open
 *
 * OTP closes what OTP created, which is correct of it and leaves exactly
 * one descriptor with no owner in Erlang. These three calls are the whole
 * of what the BEAM is missing: a sink, the flag `dup(2)` drops, and a way
 * to observe both so a test asserts rather than assumes.
 */
#include <erl_nif.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

/* **There is no floor, and the floor that was here was a mistake.**
 *
 * This refused any descriptor below 3, reasoning that `recvmsg` takes the
 * lowest FREE number and a live BEAM has none of 0, 1, 2 free. That is a
 * property of how the host happens to spawn the runtime today — stdin from
 * `/dev/null`, stdout and stderr inherited from a terminal — not a Linux
 * invariant, and Super is about to become a GUI application launched by a
 * desktop session that guarantees no such thing.
 *
 * Which made it an *ownership exception*: a descriptor the sink would
 * refuse to take, in the one module whose entire claim is that every
 * received descriptor has an exit. That is the same shape as the bug this
 * round closed, and it is not worth trading for a guard against trusted
 * runtime code passing `1`.
 *
 * The real hazard — a received channel landing on the runtime's stdout —
 * is closed where it arises: the host guarantees 0, 1 and 2 are open in
 * the child before `exec` (`fdpass::ensure_std_fds`), and the battery
 * measures that none of them is a socket. */

static ERL_NIF_TERM err2(ErlNifEnv *env, const char *tag, int e)
{
    return enif_make_tuple2(env, enif_make_atom(env, tag), enif_make_int(env, e));
}

/* The one sink. Every descriptor extracted from ancillary data ends here,
 * whether it was bound, surplus, or rejected.
 *
 * **No retry.** Linux frees the descriptor number before any error close
 * reports can occur, so calling close again can close a descriptor another
 * thread has since been handed — close(2) NOTES says so in as many words,
 * and this is a 24-core SMP VM with a thread pool. An error here means the
 * number is gone anyway. */
static ERL_NIF_TERM nif_close_received(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int fd;
    (void)argc;
    if (!enif_get_int(env, argv[0], &fd) || fd < 0)
        return enif_make_badarg(env);

    if (close(fd) == 0)
        return enif_make_atom(env, "ok");
    return err2(env, "error", errno);
}

/* `dup(2)` does not copy `FD_CLOEXEC`, so OTP's duplicate of a
 * close-on-exec descriptor is inheritable. Adopting with `dup => true` is
 * the only way to get OTP to close its own handle — and it silently undoes
 * `[:cmsg_cloexec]` on the way. This puts the flag back. */
static ERL_NIF_TERM nif_set_cloexec(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int fd, flags;
    (void)argc;
    if (!enif_get_int(env, argv[0], &fd))
        return enif_make_badarg(env);

    flags = fcntl(fd, F_GETFD);
    if (flags == -1)
        return err2(env, "error", errno);
    if (fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == -1)
        return err2(env, "error", errno);
    return enif_make_atom(env, "ok");
}

/* Three states, not two: a closed descriptor and an inheritable one both
 * fail an "is it close-on-exec" test and mean opposite things. The host's
 * `fdpass::FdState` makes the same distinction for the same reason. */
static ERL_NIF_TERM nif_state(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int fd, flags;
    (void)argc;
    if (!enif_get_int(env, argv[0], &fd))
        return enif_make_badarg(env);

    flags = fcntl(fd, F_GETFD);
    if (flags == -1)
        return enif_make_atom(env, "closed");
    return enif_make_atom(env, (flags & FD_CLOEXEC) ? "cloexec" : "inheritable");
}

/* Three functions, and no more. Notably absent is anything that *makes* a
 * raw descriptor: `dup`, `socketpair`, `open`. The runtime has exactly one
 * source of unowned descriptors — the host, over SCM_RIGHTS — and adding a
 * second one here to make the tests easier to write would widen the thing
 * this round exists to narrow. */
static ErlNifFunc funcs[] = {
    {"close_received", 1, nif_close_received},
    {"set_cloexec", 1, nif_set_cloexec},
    {"state", 1, nif_state},
};

ERL_NIF_INIT(Elixir.Ampd.NativeFd, funcs, NULL, NULL, NULL, NULL)
