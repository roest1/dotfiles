//! A make target, streamed into the pane.
//!
//! Two reader threads and a channel, ticked by `reticle::Tick` — the same shape
//! `font`'s prefetching cache already uses, so this adds no new concurrency
//! idea to the workspace.
//!
//! WHAT IS NOT HERE IS THE POINT: no sudo priming, no credential keepalive, no
//! askpass helper. Targets that escalate are not streamed at all — they detach
//! and run on the real terminal, where the real sudo can prompt in the open.
//! See ESCALATES in `console.rs`. A pane cannot host a password prompt, raw mode
//! having already taken the keyboard, and every way around that ends with this
//! process handling a password. It does not handle one.

use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;

use reticle::Tick;

/// Enough to scroll back through a long install without holding a build log in
/// memory for the life of the process.
const SCROLLBACK: usize = 2000;

pub struct Run {
    pub name: String,
    pub lines: Vec<String>,
    /// Set once the child has exited AND every reader thread has finished, not
    /// merely when it exits. try_wait() can return while the last few lines are
    /// still in flight, and marking it done there loses the tail — which is
    /// exactly the part you were watching for.
    pub done: Option<String>,
    rx: Receiver<String>,
    child: Child,
    exited: Option<ExitStatus>,
    drained: bool,
    dropped: usize,
}

impl Run {
    pub fn start(root: &Path, args: &[String], name: &str) -> std::io::Result<Self> {
        let mut child = Command::new("make")
            .arg("-C")
            .arg(root)
            // -C makes `make` announce every directory change, which is two
            // lines of noise per run in a pane whose whole job is the output.
            .arg("--no-print-directory")
            .args(args)
            // Null, not inherited. A child that unexpectedly reads stdin gets
            // EOF and fails fast instead of freezing the console against a
            // prompt nobody can see. It does NOT defend against a child that
            // opens /dev/tty itself the way sudo does — nothing here can, which
            // is why those targets are not streamed in the first place.
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let (tx, rx) = mpsc::channel();
        let mut pipes: Vec<Box<dyn Read + Send>> = Vec::new();
        if let Some(o) = child.stdout.take() {
            pipes.push(Box::new(o));
        }
        if let Some(e) = child.stderr.take() {
            pipes.push(Box::new(e));
        }
        for pipe in pipes {
            let tx = tx.clone();
            thread::spawn(move || {
                for line in BufReader::new(pipe).lines() {
                    let Ok(line) = line else { break };
                    if tx.send(line).is_err() {
                        break;
                    }
                }
            });
        }
        // The original sender must go, or the channel never disconnects and
        // `drained` never becomes true — the run would sit at "still going"
        // forever with a finished child.
        drop(tx);

        Ok(Self {
            name: name.to_string(),
            lines: Vec::new(),
            done: None,
            rx,
            child,
            exited: None,
            drained: false,
            dropped: 0,
        })
    }

    pub fn tick(&mut self) -> Tick {
        let mut changed = false;
        loop {
            match self.rx.try_recv() {
                Ok(line) => {
                    self.lines.push(line);
                    if self.lines.len() > SCROLLBACK {
                        self.lines.remove(0);
                        self.dropped += 1;
                    }
                    changed = true;
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    self.drained = true;
                    break;
                }
            }
        }

        if self.exited.is_none() {
            if let Ok(Some(status)) = self.child.try_wait() {
                self.exited = Some(status);
            }
        }

        if self.done.is_none() {
            if let (Some(status), true) = (self.exited, self.drained) {
                self.done = Some(match status.code() {
                    Some(0) => format!("make {} finished", self.name),
                    Some(c) => format!("make {} exited {c}", self.name),
                    None => format!("make {} was killed", self.name),
                });
                changed = true;
            }
        }

        if changed {
            Tick::Changed
        } else if self.done.is_some() {
            Tick::Idle
        } else {
            Tick::Busy
        }
    }

    pub fn running(&self) -> bool {
        self.done.is_none()
    }

    pub fn stop(&mut self) {
        let _ = self.child.kill();
    }

    /// The last `rows` lines, which is what you want while something is
    /// running: the tail is the news.
    pub fn tail(&self, rows: usize) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        out.push(match &self.done {
            Some(d) => d.clone(),
            None => format!("make {} …", self.name),
        });
        if self.dropped > 0 {
            out.push(format!("({} earlier lines dropped)", self.dropped));
        }
        out.push(String::new());
        let body = rows.saturating_sub(out.len());
        let start = self.lines.len().saturating_sub(body);
        out.extend(self.lines[start..].iter().cloned());
        out
    }
}

impl Drop for Run {
    /// A console that exits while a make is still going would otherwise leave
    /// it writing into a pipe nobody reads, for as long as it takes.
    fn drop(&mut self) {
        if self.done.is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}
