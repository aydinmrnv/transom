//! The wire uses VideoToolbox's hvcC + length-prefixed NAL units. Media
//! Foundation requires Annex B start codes, including inline VPS/SPS/PPS.

#[derive(Debug)]
pub struct HevcConfig {
    pub length_size: usize,
    pub profile: u32,
    pub chroma: u8,
    pub bit_depth: u8,
    pub parameter_sets: Vec<u8>,
}

impl HevcConfig {
    pub fn parse(hvcc: &[u8]) -> Result<Self, String> {
        if hvcc.len() < 23 || hvcc.len() > 1024 * 1024 || hvcc[0] != 1 {
            return Err("Invalid HEVC configuration record".into());
        }
        let length_size = usize::from((hvcc[21] & 3) + 1);
        if length_size == 3 {
            return Err("Reserved HEVC NAL length size".into());
        }
        let mut rest = &hvcc[23..];
        let mut parameter_sets = Vec::new();
        let mut found = [false; 3];
        for _ in 0..hvcc[22] {
            let header = take(&mut rest, 3)?;
            let kind = header[0] & 0x3f;
            let count = u16::from_be_bytes([header[1], header[2]]);
            for _ in 0..count {
                let size = take(&mut rest, 2)?;
                let nal = take(&mut rest, u16::from_be_bytes([size[0], size[1]]) as usize)?;
                if nal.len() < 2 || (nal[0] >> 1) & 0x3f != kind {
                    return Err("Invalid HEVC parameter-set NAL".into());
                }
                if (32..=34).contains(&kind) {
                    found[(kind - 32) as usize] = true;
                    parameter_sets.extend_from_slice(&[0, 0, 0, 1]);
                    parameter_sets.extend_from_slice(nal);
                }
            }
        }
        if !rest.is_empty() || !found.into_iter().all(|v| v) {
            return Err("HEVC configuration must contain VPS, SPS, and PPS".into());
        }
        Ok(Self {
            length_size,
            profile: u32::from(hvcc[1] & 0x1f),
            chroma: hvcc[16] & 3,
            bit_depth: (hvcc[17] & 7) + 8,
            parameter_sets,
        })
    }

    pub fn annex_b(&self, access_unit: &[u8], keyframe: bool) -> Result<Vec<u8>, String> {
        if access_unit.is_empty() {
            return Err("Empty HEVC access unit".into());
        }
        let mut rest = access_unit;
        let mut output = if keyframe {
            self.parameter_sets.clone()
        } else {
            Vec::new()
        };
        while !rest.is_empty() {
            let length = take(&mut rest, self.length_size)?;
            let size = length
                .iter()
                .fold(0usize, |n, b| (n << 8) | usize::from(*b));
            let nal = take(&mut rest, size)?;
            if nal.len() < 2 {
                return Err("Empty or truncated HEVC NAL unit".into());
            }
            output.extend_from_slice(&[0, 0, 0, 1]);
            output.extend_from_slice(nal);
        }
        Ok(output)
    }
}

fn take<'a>(data: &mut &'a [u8], size: usize) -> Result<&'a [u8], String> {
    if size > data.len() {
        return Err("Truncated HEVC packet".into());
    }
    let (head, tail) = data.split_at(size);
    *data = tail;
    Ok(head)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(length_size: u8) -> Vec<u8> {
        let mut bytes = vec![0; 23];
        bytes[0] = 1;
        bytes[1] = 1;
        bytes[16] = 0xfd;
        bytes[17] = 0xf8;
        bytes[21] = 0xfc | (length_size - 1);
        bytes[22] = 3;
        for kind in 32..=34 {
            bytes.extend_from_slice(&[kind, 0, 1, 0, 3, kind << 1, 1, 0xaa]);
        }
        bytes
    }

    #[test]
    fn converts_all_length_sizes_and_injects_parameter_sets_on_keyframes() {
        for size in [1, 2, 4] {
            let config = HevcConfig::parse(&config(size)).unwrap();
            assert_eq!((config.profile, config.chroma, config.bit_depth), (1, 1, 8));
            let mut au = vec![0; usize::from(size)];
            *au.last_mut().unwrap() = 3;
            au.extend_from_slice(&[0x26, 1, 0xab]);
            let delta = config.annex_b(&au, false).unwrap();
            assert_eq!(delta, [0, 0, 0, 1, 0x26, 1, 0xab]);
            let key = config.annex_b(&au, true).unwrap();
            assert_eq!(&key[..config.parameter_sets.len()], config.parameter_sets);
            assert_eq!(&key[config.parameter_sets.len()..], delta);
        }
    }

    #[test]
    fn rejects_truncated_config_at_every_boundary() {
        let valid = config(4);
        for end in 0..valid.len() {
            assert!(HevcConfig::parse(&valid[..end]).is_err(), "end={end}");
        }
        assert!(HevcConfig::parse(&config(3)).is_err());
        let mut missing = valid.clone();
        missing[22] = 2;
        missing.truncate(missing.len() - 8);
        assert!(HevcConfig::parse(&missing).is_err());
    }

    #[test]
    fn rejects_bad_nal_lengths_without_panicking_or_partial_output() {
        let config = HevcConfig::parse(&config(4)).unwrap();
        for bytes in [
            &[][..],
            &[0, 0],
            &[0, 0, 0, 0],
            &[0, 0, 0, 9, 1, 2],
            &[255; 4],
        ] {
            assert!(config.annex_b(bytes, true).is_err());
        }
    }
}
