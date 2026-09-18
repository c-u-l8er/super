//! Laboratory lifecycle owner for the trusted, single-process Node/Wasm driver.
//! Not a confinement policy or Carrier backend. Never accepts request-selected argv.
use std::io::{Read, Write};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;
unsafe extern "C" {
    fn prctl(option: i32, ...) -> i32;
    fn getpid() -> i32;
    fn getppid() -> i32;
}
struct InputFile(std::path::PathBuf);
impl Drop for InputFile {
    fn drop(&mut self) {
        // NodeExecutor creates and transfers ownership of this private input.
        let _ = std::fs::remove_file(&self.0);
        if let Some(parent) = self.0.parent() {
            let _ = std::fs::remove_dir(parent);
        }
    }
}
fn receipt(args: &[String]) -> std::io::Result<()> {
    if args.len() == 4 {
        return Ok(());
    }
    let path = std::path::Path::new(&args[4]);
    let pending = path.with_extension("pending");
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&pending)?;
    f.write_all(args[5].as_bytes())?;
    f.sync_all()?;
    std::fs::rename(&pending, path)?;
    std::fs::File::open(path.parent().unwrap())?.sync_all()
}
fn main() {
    std::process::exit(run());
}
fn run() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 4 && args.len() != 6 {
        return 64;
    }
    let _input = InputFile(std::path::PathBuf::from(&args[3]));
    let parent = unsafe { getpid() };
    let mut command = Command::new(&args[0]);
    command
        .args(&args[1..4])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    // Same Linux parent-death primitive used by the Carrier confinement path.
    // Check the captured parent after installation to close the pre_exec race.
    unsafe {
        command.pre_exec(move || {
            if prctl(1, 9i32, 0usize, 0usize, 0usize) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            if getppid() != parent {
                return Err(std::io::Error::from_raw_os_error(10));
            }
            Ok(())
        });
    }
    let mut child = match command.spawn() {
        Ok(c) => c,
        Err(_) => return 65,
    };
    let stdout = child.stdout.take().unwrap();
    let output = std::thread::spawn(move || {
        let mut reader = stdout;
        let mut kept = Vec::new();
        let mut buffer = [0u8; 8192];
        let mut overflow = false;
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    if kept.len() + n <= 2 * 1024 * 1024 {
                        kept.extend_from_slice(&buffer[..n]);
                    } else {
                        overflow = true;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return Err(()),
            }
        }
        if overflow {
            Err(())
        } else {
            Ok(kept)
        }
    });
    // Any byte or EOF closes the execution lease. EOF covers owner/VM death.
    let (send, recv) = mpsc::channel();
    std::thread::spawn(move || {
        let mut byte = [0];
        let _ = std::io::stdin().read(&mut byte);
        let _ = send.send(());
    });
    loop {
        match recv.recv_timeout(Duration::from_millis(5)) {
            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = child.kill();
                // 42 means reaped, not merely signalled. Never report it on wait failure.
                return if child.wait().is_ok() {
                    if receipt(&args).is_ok() {
                        42
                    } else {
                        70
                    }
                } else {
                    66
                };
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                if receipt(&args).is_err() {
                    return 70;
                }
                if !status.success() {
                    return 67;
                }
                match output.join() {
                    Ok(Ok(bytes)) => {
                        return if std::io::stdout().write_all(&bytes).is_ok() {
                            0
                        } else {
                            68
                        }
                    }
                    _ => return 69,
                }
            }
            Ok(None) => {}
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return 66;
            }
        }
    }
}
