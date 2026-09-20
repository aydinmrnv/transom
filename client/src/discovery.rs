//! Bounded, one-shot DNS-SD discovery (RFC 6762 §5.1 / §6.7). Ephemeral
//! UDP ports request unicast replies: no Bonjour installation or port-5353 bind.
use crate::connections::Connection;
use std::collections::{HashMap, HashSet};
use std::io;
use std::net::{Ipv4Addr, UdpSocket};
use std::time::{Duration, Instant};

const SERVICE: &str = "_transom._tcp.local";
const MDNS: &str = "224.0.0.251:5353";
const QUERY_ID: u16 = 0x5452;

#[derive(Default)]
struct Service {
    port: Option<u16>,
    txt: Option<Vec<(String, String)>>,
}

/// Scan every active private IPv4 interface, including Ethernet alongside Wi-Fi.
/// This blocks for at most ~2 seconds and must run off the UI thread.
pub fn scan() -> io::Result<Vec<Connection>> {
    let mut sockets = Vec::new();
    for ip in interfaces() {
        if let Ok(s) = UdpSocket::bind((ip, 0)) {
            if s.set_nonblocking(true).is_err() || s.set_multicast_ttl_v4(255).is_err() {
                continue;
            }
            #[cfg(windows)]
            if set_interface(&s, ip).is_err() {
                continue;
            }
            if s.send_to(&query(SERVICE, 12), MDNS).is_ok() {
                sockets.push(s);
            }
        }
    }
    if sockets.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotConnected,
            "No local network is available. Connect to the same network as your Mac.",
        ));
    }
    let mut services: HashMap<String, Service> = HashMap::new();
    let mut queried = HashSet::new();
    let start = Instant::now();
    let mut retried = false;
    let mut buffer = [0u8; 9000];
    while start.elapsed() < Duration::from_secs(2) {
        if !retried && start.elapsed() > Duration::from_millis(900) {
            for s in &sockets {
                let _ = s.send_to(&query(SERVICE, 12), MDNS);
            }
            retried = true;
        }
        for s in &sockets {
            // Bound work even on a noisy or hostile LAN.
            for _ in 0..64 {
                match s.recv_from(&mut buffer) {
                    Ok((n, from)) if from.port() == 5353 => {
                        if let Some(records) = records(&buffer[..n]) {
                            for r in records {
                                if r.kind == 12 && r.name.eq_ignore_ascii_case(SERVICE) {
                                    if let Some(instance) = r.target {
                                        if queried.len() < 128 && queried.insert(instance.clone()) {
                                            let _ = s.send_to(&query(&instance, 33), MDNS);
                                            let _ = s.send_to(&query(&instance, 16), MDNS);
                                        }
                                    }
                                } else if r.name.to_lowercase().ends_with(&format!(".{SERVICE}"))
                                    && services.len() < 128
                                {
                                    let entry = services.entry(r.name.to_lowercase()).or_default();
                                    if r.ttl == 0 {
                                        entry.port = None;
                                        entry.txt = None;
                                    } else if r.kind == 33 {
                                        entry.port = r.port;
                                    } else if r.kind == 16 {
                                        entry.txt = r.txt;
                                    }
                                }
                            }
                        }
                    }
                    Ok(_) => {}
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(_) => break,
                }
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut found: Vec<Connection> = services
        .values()
        .filter_map(|s| Connection::from_advertisement(s.port?, s.txt.as_ref()?))
        .collect();
    found.sort_by(|a, b| a.name.cmp(&b.name).then(a.id.cmp(&b.id)));
    let mut ids = HashSet::new();
    found.retain(|c| ids.insert(c.id.clone()));
    Ok(found)
}

fn query(name: &str, kind: u16) -> Vec<u8> {
    let mut out = vec![0x54, 0x52, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
    for label in name.split('.') {
        out.push(label.len() as u8);
        out.extend(label.as_bytes());
    }
    out.push(0);
    out.extend(kind.to_be_bytes());
    out.extend(1u16.to_be_bytes());
    out
}

/// Compression pointers are followed with a strict hop and name-length budget.
fn name(data: &[u8], cursor: &mut usize) -> Option<String> {
    let mut pos = *cursor;
    let mut jumped = false;
    let mut labels = Vec::new();
    let mut size = 0;
    for _ in 0..128 {
        let n = *data.get(pos)? as usize;
        pos += 1;
        if n == 0 {
            if !jumped {
                *cursor = pos;
            }
            return Some(labels.join("."));
        }
        if n & 0xc0 == 0xc0 {
            let next = ((n & 63) << 8) | *data.get(pos)? as usize;
            if !jumped {
                *cursor = pos + 1;
                jumped = true;
            }
            pos = next;
            continue;
        }
        if n > 63 {
            return None;
        }
        size += n + 1;
        if size > 255 {
            return None;
        }
        let label = std::str::from_utf8(data.get(pos..pos + n)?).ok()?;
        // Dots in display names are legal DNS labels. Preserve their wire form
        // for follow-up queries by rejecting only ambiguous instance labels here;
        // the host uses a UUID service label and puts the friendly name in TXT.
        if label.contains('.') {
            return None;
        }
        labels.push(label.to_string());
        pos += n;
    }
    None
}

struct Record {
    name: String,
    kind: u16,
    ttl: u32,
    target: Option<String>,
    port: Option<u16>,
    txt: Option<Vec<(String, String)>>,
}
fn u16_at(b: &[u8], p: usize) -> Option<u16> {
    Some(u16::from_be_bytes(b.get(p..p + 2)?.try_into().ok()?))
}
fn records(b: &[u8]) -> Option<Vec<Record>> {
    if u16_at(b, 0)? != QUERY_ID || u16_at(b, 2)? & 0x800f != 0x8000 {
        return None;
    }
    let questions = u16_at(b, 4)? as usize;
    let count =
        usize::from(u16_at(b, 6)?) + usize::from(u16_at(b, 8)?) + usize::from(u16_at(b, 10)?);
    if questions > 64 || count > 256 {
        return None;
    }
    let mut pos = 12;
    for _ in 0..questions {
        name(b, &mut pos)?;
        b.get(pos..pos + 4)?;
        pos += 4;
    }
    let mut out = Vec::new();
    for _ in 0..count {
        let owner = name(b, &mut pos)?;
        let kind = u16_at(b, pos)?;
        let class = u16_at(b, pos + 2)?;
        let ttl = u32::from_be_bytes(b.get(pos + 4..pos + 8)?.try_into().ok()?);
        let len = u16_at(b, pos + 8)? as usize;
        pos += 10;
        let end = pos.checked_add(len)?;
        b.get(pos..end)?;
        let mut record = Record {
            name: owner,
            kind,
            ttl,
            target: None,
            port: None,
            txt: None,
        };
        if class & 0x7fff == 1 {
            match kind {
                12 => {
                    let mut p = pos;
                    record.target = Some(name(b, &mut p)?);
                    if p > end {
                        return None;
                    }
                }
                33 if len >= 7 => {
                    record.port = u16_at(b, pos + 4);
                    let mut p = pos + 6;
                    name(b, &mut p)?;
                    if p > end {
                        return None;
                    }
                }
                16 => {
                    let mut fields = Vec::new();
                    let mut p = pos;
                    while p < end {
                        let n = b[p] as usize;
                        p += 1;
                        if p + n > end {
                            return None;
                        }
                        let text = std::str::from_utf8(&b[p..p + n]).ok()?;
                        p += n;
                        if let Some((k, v)) = text.split_once('=') {
                            fields.push((k.into(), v.into()));
                        }
                    }
                    record.txt = Some(fields);
                }
                _ => {}
            }
            out.push(record);
        }
        pos = end;
    }
    Some(out)
}

#[cfg(windows)]
fn interfaces() -> Vec<Ipv4Addr> {
    use windows::Win32::NetworkManagement::IpHelper::{GetIpAddrTable, MIB_IPADDRTABLE};
    let mut size = 0u32;
    unsafe {
        let _ = GetIpAddrTable(None, &mut size, false);
    }
    if size == 0 {
        return vec![];
    }
    let mut buf = vec![0u64; (size as usize).div_ceil(8)];
    let ptr = buf.as_mut_ptr().cast::<MIB_IPADDRTABLE>();
    unsafe {
        if GetIpAddrTable(Some(ptr), &mut size, false) != 0 {
            return vec![];
        }
        std::slice::from_raw_parts((*ptr).table.as_ptr(), (*ptr).dwNumEntries as usize)
            .iter()
            .map(|r| Ipv4Addr::from(r.dwAddr.to_ne_bytes()))
            .filter(|ip| ip.is_private() || ip.is_link_local())
            .collect()
    }
}
#[cfg(windows)]
fn set_interface(s: &UdpSocket, ip: Ipv4Addr) -> io::Result<()> {
    use std::os::windows::io::AsRawSocket;
    use windows::Win32::Networking::WinSock::{setsockopt, IPPROTO_IP, IP_MULTICAST_IF, SOCKET};
    if unsafe {
        setsockopt(
            SOCKET(s.as_raw_socket() as usize),
            IPPROTO_IP.0,
            IP_MULTICAST_IF,
            Some(&ip.octets()),
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
#[cfg(not(windows))]
fn interfaces() -> Vec<Ipv4Addr> {
    vec![Ipv4Addr::UNSPECIFIED]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn compressed_names_and_cycles() {
        let b = [3, b'm', b'a', b'c', 0, 0xc0, 0];
        let mut p = 5;
        assert_eq!(name(&b, &mut p).unwrap(), "mac");
        assert_eq!(p, 7);
        assert!(name(&[0xc0, 0], &mut 0).is_none());
        assert!(name(&[63, 1, 2], &mut 0).is_none());
    }
    #[test]
    fn parses_real_dns_record_layout_and_rejects_truncation() {
        let mut b = query(SERVICE, 12);
        b[2] = 0x84;
        b[7] = 1;
        b.extend([0xc0, 12, 0, 12, 0, 1, 0, 0, 0, 120]);
        let mut instance = vec![3, b'a', b'b', b'c'];
        instance.extend([0xc0, 12]);
        b.extend((instance.len() as u16).to_be_bytes());
        b.extend(instance);
        let r = records(&b).unwrap();
        assert_eq!(r[0].target.as_deref(), Some("abc._transom._tcp.local"));
        for n in 0..b.len() {
            assert!(records(&b[..n]).is_none());
        }
    }
    #[test]
    fn validates_discovery_metadata() {
        let mut f = vec![
            ("v".into(), "1".into()),
            ("id".into(), "uuid".into()),
            ("name".into(), "Mac Studio".into()),
            ("addr".into(), "192.168.1.5".into()),
            ("video".into(), "48200".into()),
        ];
        assert_eq!(
            Connection::from_advertisement(48100, &f)
                .unwrap()
                .video_port,
            Some(48200)
        );
        f[3].1 = "8.8.8.8".into();
        assert!(Connection::from_advertisement(48100, &f).is_none());
        f[3].1 = "192.168.1.5".into();
        f[4].1 = "0".into();
        assert!(Connection::from_advertisement(48100, &f)
            .unwrap()
            .video_port
            .is_none());
        f[0].1 = "2".into();
        assert!(Connection::from_advertisement(48100, &f).is_none());
    }
}
