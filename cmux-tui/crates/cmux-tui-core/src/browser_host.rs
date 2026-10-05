#![allow(dead_code, unused_imports)] // red commit: the host is not started yet
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

/// Adds `CMUX_BROWSER_HOST_SOCKET` to terminals (not yet).
pub fn add_terminal_env(_daemon_socket: &Path, _options: &mut crate::SurfaceOptions) {}

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

fn start(_: &Arc<Inner>, _: &Path, _: &Path) -> Result<Running, String> {
    Err("the browser host is not started yet".into())
}
