#![cfg_attr(not(unix), allow(dead_code))]
//! The daemon's browser host (plans/cmux-next/browser-host.md, step c2).
//!
//! The daemon starts one `cmux-browser-host` for itself on the first
//! `browser-host-provider` request, restarts it with [`Backoff`] after a
//! crash, and stops it with itself: the host runs `serve --supervised`, so it
//! exits when its stdin (the daemon's end of a pipe) reaches its end, also when
//! the daemon dies.
//!
//! One host per daemon, not per machine: its sockets are in a directory of
//! the daemon's own runtime directory, so the stable app's daemon and a tagged
//! build's daemon never share a host. Terminals the daemon creates get the
//! agent socket as `CMUX_BROWSER_HOST_SOCKET` (the path only).
//!
//! The provider secret is 32 random bytes per host launch. The daemon writes
//! it to the host on an inherited pipe (fd 3, never argv or env) and gives it
//! only to the verified local app (`server/browser_host_command.rs`), with the
//! host's pid, so the app dials the provider socket only when its peer is that
//! process. A restarted host has a new secret. The secret is never logged.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use crate::backoff::Backoff;

/// The environment variable that names the agent socket of the daemon's
/// browser host in every terminal the daemon creates.
pub const BROWSER_HOST_SOCKET_ENV: &str = "CMUX_BROWSER_HOST_SOCKET";
/// Advertised by `identify` once `browser-host-provider` exists.
pub(crate) const BROWSER_HOST_PROVIDER_CAPABILITY: &str = "browser-host-provider-v1";
/// How long a starting host may take to report that its sockets listen.
const READY_TIMEOUT: Duration = Duration::from_secs(10);
/// A host that ran at least this long before it stopped restarts at the
/// first backoff delay again.
const HEALTHY_RUN: Duration = Duration::from_secs(30);
/// The agent socket's file name. The host puts its provider socket
/// (`browser-host-provider.sock`) in the same directory.
const SOCKET_FILE: &str = "browser-host.sock";
const PROVIDER_SOCKET_FILE: &str = "browser-host-provider.sock";

/// The agent socket of the browser host of the daemon on `daemon_socket`:
/// `bh-<digest>/browser-host.sock` beside it (12 hex digits of the daemon
/// socket path's SHA-256), else under `/tmp/cmux-tui-<uid>/` when that path
/// is too long for a Unix socket.
pub fn socket_path_for(daemon_socket: &Path) -> PathBuf {
    use sha2::{Digest, Sha256};
    let digest = format!("{:x}", Sha256::digest(daemon_socket.as_os_str().as_encoded_bytes()));
    let leaf = format!("bh-{}", &digest[..12]);
    let beside = daemon_socket.parent().unwrap_or_else(|| Path::new("/tmp")).join(&leaf);
    #[cfg(unix)]
    if !crate::server::unix_socket_path_fits(&beside.join(PROVIDER_SOCKET_FILE)) {
        return crate::platform::fallback_runtime_dir().join(leaf).join(SOCKET_FILE);
    }
    beside.join(SOCKET_FILE)
}

/// Adds `CMUX_BROWSER_HOST_SOCKET` (the socket path only) to the environment
/// of every terminal the daemon on `daemon_socket` creates.
pub fn add_terminal_env(daemon_socket: &Path, options: &mut crate::SurfaceOptions) {
    let socket = socket_path_for(daemon_socket).display().to_string();
    options.extra_env.push((BROWSER_HOST_SOCKET_ENV.into(), socket));
}

impl crate::mux::Mux {
    /// Lets this daemon start its browser host (`browser-host-provider`):
    /// the host binary is `CMUX_BROWSER_HOST_BIN`, else `cmux-browser-host`
    /// beside the daemon executable.
    pub fn configure_browser_host(&self, daemon_socket: &Path) {
        self.browser_host.configure(resolve_binary(), socket_path_for(daemon_socket));
    }
}

/// `CMUX_BROWSER_HOST_BIN`, else `cmux-browser-host` next to the daemon
/// executable. `None` when neither is a file.
fn resolve_binary() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CMUX_BROWSER_HOST_BIN").map(PathBuf::from) {
        return path.is_file().then_some(path);
    }
    let path = std::env::current_exe().ok()?.parent()?.join("cmux-browser-host");
    path.is_file().then_some(path)
}

/// What the verified app needs to dial the provider socket.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct ProviderCredentials {
    /// The provider socket (`browser-host-provider.sock`).
    pub(crate) socket: PathBuf,
    /// The host launch's provider secret (64 lowercase hex digits).
    pub(crate) secret: String,
    /// The host's pid: the app checks the provider socket's peer against it.
    pub(crate) host_pid: u32,
}

impl std::fmt::Debug for ProviderCredentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderCredentials")
            .field("socket", &self.socket)
            .field("secret", &"<redacted>")
            .field("host_pid", &self.host_pid)
            .finish()
    }
}

/// The daemon's one browser host. Unconfigured until
/// [`Mux::configure_browser_host`](crate::mux::Mux::configure_browser_host).
#[derive(Default)]
pub(crate) struct BrowserHostSupervisor {
    inner: Arc<Inner>,
}

#[derive(Default)]
struct Inner {
    config: Mutex<Option<Config>>,
    state: Mutex<State>,
    /// Held while a host starts, so two callers never start two hosts.
    starting: Mutex<()>,
    backoff: Mutex<Option<Backoff>>,
}

#[derive(Clone)]
struct Config {
    binary: Option<PathBuf>,
    socket: PathBuf,
}

#[derive(Default)]
enum State {
    #[default]
    Idle,
    Running(Running),
}

struct Running {
    credentials: ProviderCredentials,
    /// The daemon's end of the host's stdin; dropping it stops the host.
    #[cfg(unix)]
    _stdin: std::process::ChildStdin,
}

impl BrowserHostSupervisor {
    pub(crate) fn configure(&self, binary: Option<PathBuf>, socket: PathBuf) {
        *lock(&self.inner.config) = Some(Config { binary, socket });
    }

    /// The running host's credentials, starting the host first when none
    /// runs. `Err` names why there is no host (no configuration, no binary,
    /// a start failure); it never carries the secret.
    pub(crate) fn credentials(&self) -> Result<ProviderCredentials, String> {
        Inner::credentials(&self.inner)
    }

    /// The running host's pid, if any (tests).
    #[cfg(test)]
    pub(crate) fn running_pid(&self) -> Option<u32> {
        match &*lock(&self.inner.state) {
            State::Running(running) => Some(running.credentials.host_pid),
            State::Idle => None,
        }
    }
}

impl Inner {
    fn credentials(this: &Arc<Self>) -> Result<ProviderCredentials, String> {
        if let State::Running(running) = &*lock(&this.state) {
            return Ok(running.credentials.clone());
        }
        let _starting = lock(&this.starting);
        if let State::Running(running) = &*lock(&this.state) {
            return Ok(running.credentials.clone());
        }
        let config = lock(&this.config).clone().ok_or("this daemon has no browser host")?;
        let binary = config.binary.ok_or(
            "cmux-browser-host was not found beside the daemon (set CMUX_BROWSER_HOST_BIN)",
        )?;
        let running = start(this, &binary, &config.socket)?;
        let credentials = running.credentials.clone();
        *lock(&this.state) = State::Running(running);
        Ok(credentials)
    }

    /// The host with `pid` stopped after running `ran`: forget it, and start
    /// a new one after the backoff delay unless the daemon dropped the
    /// supervisor meanwhile. Runs on the host's watcher thread.
    fn host_stopped(this: &Weak<Self>, pid: u32, ran: Duration) {
        let delay = {
            let Some(inner) = this.upgrade() else { return };
            let mut state = lock(&inner.state);
            if matches!(&*state, State::Running(running) if running.credentials.host_pid == pid) {
                *state = State::Idle;
            }
            drop(state);
            let mut backoff = lock(&inner.backoff);
            let backoff = backoff.get_or_insert_with(|| {
                Backoff::new(Duration::from_millis(200), Duration::from_secs(30))
            });
            if ran >= HEALTHY_RUN {
                backoff.reset();
            }
            backoff.next_delay()
        };
        eprintln!("cmux-tui: browser host {pid} stopped after {} ms; restarting", ran.as_millis());
        // A bounded restart delay on the watcher thread, not a synchronization.
        std::thread::sleep(delay);
        let Some(inner) = this.upgrade() else { return };
        if let Err(error) = Self::credentials(&inner) {
            eprintln!("cmux-tui: browser host restart failed: {error}");
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// 32 random bytes as 64 lowercase hex digits.
fn mint_secret() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|error| format!("cannot mint a provider secret: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(not(unix))]
fn start(_: &Arc<Inner>, _: &Path, _: &Path) -> Result<Running, String> {
    Err("the browser host runs on macOS and Linux only".into())
}

/// Starts the host on `socket`, gives it a new secret on fd 3, and waits for
/// its `ready` line. A watcher thread reaps it and calls
/// [`Inner::host_stopped`].
#[cfg(unix)]
fn start(inner: &Arc<Inner>, binary: &Path, socket: &Path) -> Result<Running, String> {
    use std::io::{BufRead, BufReader, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};

    let dir = socket.parent().ok_or("the browser host socket has no directory")?;
    std::fs::create_dir_all(dir)
        .and_then(|()| std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)))
        .map_err(|error| format!("cannot prepare {}: {error}", dir.display()))?;
    let secret = mint_secret()?;
    let (secret_read, mut secret_write) =
        std::io::pipe().map_err(|error| format!("cannot open the secret pipe: {error}"))?;
    let fd = secret_read.as_raw_fd();
    let mut command = Command::new(binary);
    command
        .args(["serve", "--provider-secret-fd", "3", "--supervised", "--socket"])
        .arg(socket)
        // The host then leaves the directory's mode to the daemon.
        .env(BROWSER_HOST_SOCKET_ENV, socket)
        .env_remove("CMUX_BROWSER_HOST_BIN")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        // Its own process group: a signal to the daemon's group does not
        // reach it; it stops when its stdin ends.
        .process_group(0);
    // SAFETY: sysconf before the fork.
    let max_fd = match unsafe { libc::sysconf(libc::_SC_OPEN_MAX) } {
        n if n > 0 => n.min(65_536) as libc::c_int,
        _ => 4096,
    };
    // SAFETY: only async-signal-safe calls between fork and exec.
    unsafe { command.pre_exec(move || secret_fd_only(fd, max_fd)) };
    let mut child =
        command.spawn().map_err(|error| format!("cannot start the browser host: {error}"))?;
    drop(secret_read);
    let pid = child.id();
    let stdin = child.stdin.take().ok_or("the browser host has no stdin")?;
    let stdout = child.stdout.take().ok_or("the browser host has no stdout")?;
    let written = secret_write.write_all(secret.as_bytes());
    drop(secret_write);
    let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
    let reader = std::thread::Builder::new().name("browser-host-ready".into()).spawn(move || {
        let mut line = String::new();
        let ok = BufReader::new(stdout).read_line(&mut line).is_ok() && line == "ready\n";
        let _ = ready_tx.send(ok);
    });
    let ready = written.is_ok()
        && reader.is_ok()
        && matches!(ready_rx.recv_timeout(READY_TIMEOUT), Ok(true));
    if !ready {
        let _ = child.kill();
        let status = child.wait();
        return Err(format!("the browser host did not start ({status:?})"));
    }
    let started = Instant::now();
    let watcher = Arc::downgrade(inner);
    std::thread::Builder::new()
        .name("browser-host-watch".into())
        .spawn(move || {
            let _ = child.wait();
            Inner::host_stopped(&watcher, pid, started.elapsed());
        })
        .map_err(|error| format!("cannot watch the browser host: {error}"))?;
    let provider = socket.with_file_name(PROVIDER_SOCKET_FILE);
    Ok(Running {
        credentials: ProviderCredentials { socket: provider, secret, host_pid: pid },
        _stdin: stdin,
    })
}

/// In the forked child: the secret pipe becomes fd 3; every other
/// descriptor above stderr is closed.
#[cfg(unix)]
fn secret_fd_only(fd: libc::c_int, max_fd: libc::c_int) -> std::io::Result<()> {
    // SAFETY: plain descriptor syscalls on this (forked, single-threaded) process.
    unsafe {
        if fd == 3 {
            if libc::fcntl(3, libc::F_SETFD, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
        } else if libc::dup2(fd, 3) != 3 {
            return Err(std::io::Error::last_os_error());
        }
        for other in 4..max_fd {
            libc::close(other);
        }
    }
    Ok(())
}
