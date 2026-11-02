//! Controls whatever is playing media on this computer (spec §9.4 `music.control` and
//! `music.now_playing`). No login and no network: it talks to the operating system.
//!
//! Windows: the system media session (what the volume flyout and the lock screen use), so
//! pause, play, next and previous reach Spotify, a browser tab or any player that
//! registers, and "now playing" comes from the same session. Volume and mute press the
//! system volume keys. Other systems return `Unsupported` until their adapter is written
//! (macOS: Spotify and Music through AppleScript, Linux: MPRIS), so nothing pretends to work.

/// What can be asked of the media session. Fixed list: no text from anyone reaches the OS.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Play,
    Pause,
    Next,
    Previous,
    VolumeUp,
    VolumeDown,
    /// The system mute key toggles: pressing it again unmutes.
    MuteToggle,
}

/// The track the system says is current. The strings come from the playing app, so they
/// are untrusted text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NowPlaying {
    pub title: String,
    pub artist: String,
    pub playing: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaError {
    /// This operating system has no adapter yet (only built on the systems without one).
    #[cfg_attr(windows, allow(dead_code))]
    Unsupported,
    /// No app has a media session open.
    #[cfg_attr(not(windows), allow(dead_code))]
    NothingPlaying,
    /// The app has a session but did not accept the command.
    #[cfg_attr(not(windows), allow(dead_code))]
    Refused,
    #[cfg_attr(not(windows), allow(dead_code))]
    Failed,
}

/// Blocking: the tool calls it on a blocking thread.
pub fn send(cmd: Command) -> Result<(), MediaError> {
    imp::send(cmd)
}

/// `Ok(None)` means no app has a media session. Blocking.
pub fn now_playing() -> Result<Option<NowPlaying>, MediaError> {
    imp::now_playing()
}

#[cfg(windows)]
mod imp {
    use super::{Command, MediaError, NowPlaying};
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSession as Session,
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };
    use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx, CoUninitialize};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, SendInput, VK_VOLUME_DOWN,
        VK_VOLUME_MUTE, VK_VOLUME_UP,
    };

    /// One volume command moves the volume by this many key presses (each is about 2%).
    const VOLUME_PRESSES: usize = 5;

    /// The media session API needs a COM apartment on the calling thread, and a pooled
    /// thread may not have one, so the work runs on a short-lived thread of its own.
    fn in_apartment<T: Send + 'static>(
        f: impl FnOnce() -> Result<T, MediaError> + Send + 'static,
    ) -> Result<T, MediaError> {
        std::thread::Builder::new()
            .name("media-control".into())
            .spawn(move || {
                // SAFETY: balanced by CoUninitialize below whenever it succeeded.
                let init = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
                let out = f();
                if init.is_ok() {
                    unsafe { CoUninitialize() };
                }
                out
            })
            .map_err(|_| MediaError::Failed)?
            .join()
            .map_err(|_| MediaError::Failed)?
    }

    fn current_session() -> Result<Session, MediaError> {
        let manager = Manager::RequestAsync()
            .and_then(|op| op.join())
            .map_err(|_| MediaError::Failed)?;
        // No session at all comes back as an error from the system.
        manager
            .GetCurrentSession()
            .map_err(|_| MediaError::NothingPlaying)
    }

    fn accepted(r: windows::core::Result<bool>) -> Result<(), MediaError> {
        match r {
            Ok(true) => Ok(()),
            Ok(false) => Err(MediaError::Refused),
            Err(_) => Err(MediaError::Failed),
        }
    }

    fn press(vk: u16, times: usize) -> Result<(), MediaError> {
        let key = |flags| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: vk,
                    wScan: 0,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };
        let mut inputs = Vec::with_capacity(times * 2);
        for _ in 0..times {
            inputs.push(key(0));
            inputs.push(key(KEYEVENTF_KEYUP));
        }
        // SAFETY: `inputs` is a valid array of INPUT structures and the size is that of one.
        let sent = unsafe {
            SendInput(
                inputs.len() as u32,
                inputs.as_ptr(),
                std::mem::size_of::<INPUT>() as i32,
            )
        };
        if sent as usize == inputs.len() {
            Ok(())
        } else {
            Err(MediaError::Failed)
        }
    }

    pub fn send(cmd: Command) -> Result<(), MediaError> {
        match cmd {
            Command::VolumeUp => press(VK_VOLUME_UP, VOLUME_PRESSES),
            Command::VolumeDown => press(VK_VOLUME_DOWN, VOLUME_PRESSES),
            Command::MuteToggle => press(VK_VOLUME_MUTE, 1),
            Command::Play | Command::Pause | Command::Next | Command::Previous => {
                in_apartment(move || {
                    let s = current_session()?;
                    accepted(
                        match cmd {
                            Command::Play => s.TryPlayAsync(),
                            Command::Pause => s.TryPauseAsync(),
                            Command::Next => s.TrySkipNextAsync(),
                            _ => s.TrySkipPreviousAsync(),
                        }
                        .and_then(|op| op.join()),
                    )
                })
            }
        }
    }

    pub fn now_playing() -> Result<Option<NowPlaying>, MediaError> {
        in_apartment(|| {
            let s = match current_session() {
                Ok(s) => s,
                Err(MediaError::NothingPlaying) => return Ok(None),
                Err(e) => return Err(e),
            };
            let playing = s
                .GetPlaybackInfo()
                .and_then(|i| i.PlaybackStatus())
                .map(|st| st.0 == Status::Playing.0)
                .unwrap_or(false);
            let props = s
                .TryGetMediaPropertiesAsync()
                .and_then(|op| op.join())
                .map_err(|_| MediaError::Failed)?;
            let text = |h: windows::core::Result<windows::core::HSTRING>| {
                h.map(|h| h.to_string_lossy()).unwrap_or_default()
            };
            let (title, artist) = (text(props.Title()), text(props.Artist()));
            if title.is_empty() && artist.is_empty() {
                return Ok(None);
            }
            Ok(Some(NowPlaying {
                title,
                artist,
                playing,
            }))
        })
    }
}

#[cfg(not(windows))]
mod imp {
    use super::{Command, MediaError, NowPlaying};

    pub fn send(_: Command) -> Result<(), MediaError> {
        Err(MediaError::Unsupported)
    }

    pub fn now_playing() -> Result<Option<NowPlaying>, MediaError> {
        Err(MediaError::Unsupported)
    }
}

#[cfg(all(test, not(windows)))]
mod tests {
    use super::*;

    #[test]
    fn systems_without_an_adapter_say_so_and_do_nothing() {
        assert_eq!(send(Command::Pause), Err(MediaError::Unsupported));
        assert_eq!(send(Command::VolumeUp), Err(MediaError::Unsupported));
        assert_eq!(now_playing(), Err(MediaError::Unsupported));
    }
}
