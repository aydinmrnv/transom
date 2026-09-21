//! Saved endpoints and the discovery contract. No renderer or OS dependencies.
use crate::wire::json::Value;
use std::io;
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Connection {
    pub id: String,
    pub name: String,
    pub host: String,
    pub control_port: u16,
    pub video_port: Option<u16>,
}

impl Connection {
    pub fn same_destination(&self, other: &Self) -> bool {
        self.id == other.id
            || (self.host.eq_ignore_ascii_case(&other.host)
                && self.control_port == other.control_port
                && self.video_port == other.video_port)
    }
    pub fn manual(host: &str, control: &str, video: &str) -> Result<Self, String> {
        let host = host.trim().trim_end_matches('.');
        if host.is_empty()
            || host.len() > 253
            || host
                .chars()
                .any(|c| c.is_whitespace() || matches!(c, '/' | '\\' | '\0'))
        {
            return Err("Enter a Mac hostname (such as Mac-Studio.local) or an IP address.".into());
        }
        let control_port = port(control).ok_or("Control port must be between 1 and 65535.")?;
        let video_port = if video.trim().is_empty() {
            None
        } else {
            Some(
                port(video)
                    .ok_or("Video port must be between 1 and 65535, or blank to disable video.")?,
            )
        };
        if video_port == Some(control_port) {
            return Err("Control and video ports must be different.".into());
        }
        Ok(Self {
            id: format!("manual:{}:{control_port}", host.to_lowercase()),
            name: host.into(),
            host: host.into(),
            control_port,
            video_port,
        })
    }

    pub fn from_advertisement(control_port: u16, fields: &[(String, String)]) -> Option<Self> {
        let get = |key: &str| {
            fields
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.as_str())
        };
        if get("v")? != "1" || control_port == 0 {
            return None;
        }
        let host = get("addr")?;
        let ip: std::net::Ipv4Addr = host.parse().ok()?;
        if !(ip.is_private() || ip.is_link_local()) {
            return None;
        }
        let id = get("id")?;
        if id.is_empty() || id.len() > 128 {
            return None;
        }
        let name = get("name")?.trim();
        if name.is_empty() || name.chars().any(char::is_control) {
            return None;
        }
        let video_port = match get("video")? {
            "0" => None,
            p => Some(port(p)?),
        };
        if video_port == Some(control_port) {
            return None;
        }
        Some(Self {
            id: id.into(),
            name: name.into(),
            host: host.into(),
            control_port,
            video_port,
        })
    }

    fn json(&self) -> Value {
        Value::object(vec![
            ("id", Value::str(&self.id)),
            ("name", Value::str(&self.name)),
            ("host", Value::str(&self.host)),
            ("control", Value::uint(self.control_port.into())),
            (
                "video",
                self.video_port
                    .map(|p| Value::uint(p.into()))
                    .unwrap_or(Value::Null),
            ),
        ])
    }
}

fn port(s: &str) -> Option<u16> {
    s.trim().parse().ok().filter(|p| *p != 0)
}

pub fn remember(saved: &mut Vec<Connection>, connection: Connection) {
    saved.retain(|c| !c.same_destination(&connection));
    saved.insert(0, connection);
    saved.truncate(12);
}

/// Discovery supplies the current name/address; saved endpoints fill the gaps.
pub fn available(nearby: &[Connection], saved: &[Connection]) -> Vec<Connection> {
    let mut rows: Vec<Connection> = Vec::new();
    for c in nearby.iter().chain(saved) {
        if !rows.iter().any(|row| row.same_destination(c)) {
            rows.push(c.clone());
        }
    }
    rows
}

pub fn load(path: &Path) -> io::Result<Vec<Connection>> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    if text.len() > 64 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Saved connections file is too large",
        ));
    }
    let root = Value::parse(&text).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    let rows = root
        .as_array()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Invalid connections file"))?;
    Ok(rows
        .iter()
        .take(12)
        .filter_map(|v| {
            let get = |k| v.get(k).and_then(Value::as_str);
            let control = v.get("control")?.as_u64()?.to_string();
            let video = v
                .get("video")?
                .as_u64()
                .map(|n| n.to_string())
                .unwrap_or_default();
            let mut c = Connection::manual(get("host")?, &control, &video).ok()?;
            c.id = get("id")?.into();
            c.name = get("name")?.into();
            Some(c)
        })
        .collect())
}

pub fn save(path: &Path, saved: &[Connection]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // Write completely before replacing the previous preferences. Windows rename
    // cannot overwrite, so use its atomic replace primitive on that platform.
    let temp = path.with_extension(format!("{}.tmp", std::process::id()));
    std::fs::write(
        &temp,
        Value::Array(saved.iter().map(Connection::json).collect()).to_json(),
    )?;
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows::core::PCWSTR;
        use windows::Win32::Storage::FileSystem::{
            MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
        };
        let from: Vec<u16> = temp.as_os_str().encode_wide().chain(Some(0)).collect();
        let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        unsafe {
            MoveFileExW(
                PCWSTR(from.as_ptr()),
                PCWSTR(to.as_ptr()),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        }
        .map_err(io::Error::other)
    }
    #[cfg(not(windows))]
    {
        std::fs::rename(temp, path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovery_merges_manual_copy_but_preserves_distinct_services() {
        let manual = Connection::manual("192.168.0.37", "7002", "7001").unwrap();
        let mut discovered = manual.clone();
        discovered.id = "mac-studio".into();
        discovered.name = "Mac Studio".into();
        let other = Connection::manual("192.168.0.37", "7102", "7101").unwrap();
        assert_eq!(
            available(&[discovered.clone()], &[manual.clone(), other.clone()]),
            vec![discovered.clone(), other]
        );
        let mut saved = vec![manual];
        remember(&mut saved, discovered.clone());
        assert_eq!(saved, vec![discovered]);
    }
    #[test]
    fn manual_custom_ports_and_hostnames() {
        let c = Connection::manual(" Mac-Studio.local ", "48000", "48001").unwrap();
        assert_eq!(c.host, "Mac-Studio.local");
        assert_eq!(c.video_port, Some(48001));
        assert!(Connection::manual("foo", "0", "").is_err());
        assert!(Connection::manual("foo", "5", "5").is_err());
        assert!(Connection::manual("https://foo", "5", "6").is_err());
    }
    #[test]
    fn remembers_by_stable_id_after_address_change() {
        let mut c = Connection::manual("192.168.1.2", "47100", "47101").unwrap();
        c.id = "stable".into();
        let mut saved = vec![c.clone()];
        c.host = "192.168.1.7".into();
        remember(&mut saved, c.clone());
        assert_eq!(saved, vec![c]);
    }
    #[test]
    fn preferences_round_trip_and_replace_unicode() {
        let path =
            std::env::temp_dir().join(format!("transom-settings-{}.json", std::process::id()));
        let mut c = Connection::manual("mac.local", "47100", "").unwrap();
        c.name = "Aydin’s Mac ".into();
        save(&path, &[c.clone()]).unwrap();
        assert_eq!(load(&path).unwrap(), vec![c]);
        save(&path, &[]).unwrap();
        assert!(load(&path).unwrap().is_empty());
        std::fs::remove_file(path).unwrap();
    }
}
