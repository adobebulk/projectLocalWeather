use crate::interpolation::EstimatedLocalConditions;

pub struct DisplayLines {
    pub line1: String,
    pub line2: String,
}

const MAX_LINE_LEN: usize = 16;

const PHEN_PRIORITY: &[&str] = &["TS", "IC", "SN", "RA", "FG", "SM", "HZ", "MX"];

pub fn format_display(estimated: &EstimatedLocalConditions) -> DisplayLines {
    let visibility = visibility_code(estimated.visibility_m);
    let phenomenon = dominant_phenomenon(&estimated);
    let wind = wind_block(estimated);

    let mut blocks = vec![visibility.clone(), phenomenon.clone(), wind.clone()];
    let mut line1 = join_blocks(&blocks);

    line1 = truncate_line1(line1, &mut blocks, &phenomenon);

    let line2 = line2_text(&phenomenon, estimated);

    DisplayLines { line1, line2 }
}

fn join_blocks(blocks: &[String]) -> String {
    blocks
        .iter()
        .filter(|b| !b.is_empty())
        .cloned()
        .collect::<Vec<_>>()
        .join(" ")
}

fn truncate_line1(mut line: String, blocks: &mut Vec<String>, phenomenon: &String) -> String {
    if line.len() < MAX_LINE_LEN {
        return line;
    }

    if drop_gust(blocks) {
        line = join_blocks(blocks);
        if line.len() <= MAX_LINE_LEN {
            return line;
        }
    }

    if ["FG", "SM", "HZ"].contains(&phenomenon.as_str()) {
        if drop_visibility(blocks) {
            line = join_blocks(blocks);
            if line.len() <= MAX_LINE_LEN {
                return line;
            }
        }
    }

    if drop_benign_visibility(&line) {
        line = join_blocks(blocks);
    }

    if line.len() > MAX_LINE_LEN {
        line = line[..MAX_LINE_LEN].trim_end().to_string();
    }

    line
}

fn drop_gust(blocks: &mut Vec<String>) -> bool {
    if let Some(wind) = blocks.pop() {
        if wind.contains('G') {
            let base = wind.split('G').next().unwrap_or("");
            if !base.is_empty() {
                blocks.push(base.to_string());
            }
            return true;
        }
        blocks.push(wind);
    }
    false
}

fn drop_visibility(blocks: &mut Vec<String>) -> bool {
    if blocks.len() >= 1 {
        blocks.remove(0);
        return true;
    }
    false
}

fn drop_benign_visibility(line: &str) -> bool {
    line.starts_with("V10 ")
}

fn visibility_code(visibility_m: u16) -> String {
    match visibility_m {
        v if v >= 8000 => "V10".into(),
        v if v >= 5000 => "V5".into(),
        v if v >= 2000 => "V2".into(),
        _ => "VL".into(),
    }
}

fn dominant_phenomenon(estimated: &EstimatedLocalConditions) -> String {
    for code in PHEN_PRIORITY {
        if estimated.precip_kind == phenomenon_code(code) {
            let marker = intensity_marker(estimated);
            return format!("{}{}", marker_pheno(code), marker);
        }
    }
    "".into()
}

fn phenomenon_code(code: &str) -> u8 {
    match code {
        "TS" => 9,
        "IC" => 4,
        "SN" => 2,
        "RA" => 1,
        "FG" => 5,
        "SM" => 7,
        "HZ" => 6,
        "MX" => 8,
        _ => 0,
    }
}

fn marker_pheno(code: &str) -> &str {
    match code {
        "TS" => "TS",
        "IC" => "IC",
        "SN" => "SN",
        "RA" => "RA",
        "FG" => "FG",
        "SM" => "SM",
        "HZ" => "HZ",
        "MX" => "MX",
        _ => "",
    }
}

fn intensity_marker(estimated: &EstimatedLocalConditions) -> &'static str {
    if estimated.precip_intensity >= 3 {
        "+"
    } else if estimated.precip_intensity == 1 {
        "-"
    } else {
        ""
    }
}

fn wind_block(estimated: &EstimatedLocalConditions) -> String {
    let gust = estimated.wind_gust_mps_tenths / 10;
    let base = estimated.wind_speed_mps_tenths / 10;
    if gust > 0 {
        format!("W{}G{}", base, gust)
    } else {
        format!("W{}", base)
    }
}

fn line2_text(phenomenon: &String, estimated: &EstimatedLocalConditions) -> String {
    let confidence = (estimated.confidence_score / 10) * 10;
    let label = if estimated.hazard_flags & (1 << 1) != 0 {
        "SVRSTM"
    } else if estimated.hazard_flags & (1 << 7) != 0 {
        "TORNDO"
    } else {
        match phenomenon.as_str() {
            "TS" => "TS",
            "RA" => "RAIN",
            "SN" => "SNOW",
            "FG" => "FOG",
            "IC" => "ICING",
            "SM" => "SMOKE",
            "HZ" => "DEGRD",
            "MX" => "MIXED",
            "" => "CLEAR",
            _ => "CLEAR",
        }
    };

    format!("{:<6} C{}%", label, confidence)
}

#[cfg(test)]
mod tests {
    use super::{format_display, DisplayLines};
    use crate::interpolation::EstimatedLocalConditions;

    fn base_conditions() -> EstimatedLocalConditions {
        EstimatedLocalConditions {
            air_temp_c_tenths: 500,
            wind_speed_mps_tenths: 80,
            wind_gust_mps_tenths: 120,
            precip_prob_pct: 20,
            precip_kind: 1,
            precip_intensity: 2,
            visibility_m: 5000,
            hazard_flags: 0,
            confidence_score: 85,
        }
    }

    fn assert_length(lines: &DisplayLines) {
        assert!(lines.line1.len() <= 16);
        assert!(lines.line2.len() <= 16);
    }

    #[test]
    fn clear_conditions() {
        let mut conditions = base_conditions();
        conditions.precip_kind = 0;
        conditions.visibility_m = 9000;
        let lines = format_display(&conditions);
        assert_length(&lines);
    }

    #[test]
    fn rain_case() {
        let lines = format_display(&base_conditions());
        assert!(lines.line1.contains("RA"));
        assert_length(&lines);
    }

    #[test]
    fn heavy_snow_case() {
        let mut conditions = base_conditions();
        conditions.precip_kind = 2;
        conditions.precip_intensity = 3;
        conditions.visibility_m = 1500;
        let lines = format_display(&conditions);
        assert!(lines.line1.contains("SN+"));
        assert_length(&lines);
    }

    #[test]
    fn fog_case() {
        let mut conditions = base_conditions();
        conditions.precip_kind = 5;
        conditions.visibility_m = 500;
        let lines = format_display(&conditions);
        assert!(lines.line1.starts_with("VL FG"));
        assert_length(&lines);
    }

    #[test]
        fn severe_thunderstorm_case() {
        let mut conditions = base_conditions();
        conditions.precip_kind = 9;
        conditions.precip_intensity = 4;
        conditions.hazard_flags = 1 << 1;
        let lines = format_display(&conditions);
        assert!(lines.line1.contains("TS+"));
        assert!(lines.line2.contains("SVRSTM"));
        assert_length(&lines);
    }

    #[test]
    fn smoke_case() {
        let mut conditions = base_conditions();
        conditions.precip_kind = 7;
        conditions.precip_prob_pct = 80;
        let lines = format_display(&conditions);
        assert!(lines.line1.contains("SM"));
        assert!(lines.line2.contains("SMOKE"));
        assert_length(&lines);
    }

    #[test]
    fn degraded_confidence_case() {
        let mut conditions = base_conditions();
        conditions.confidence_score = 35;
        let lines = format_display(&conditions);
        assert!(lines.line2.contains("C30%"));
        assert_length(&lines);
    }

    #[test]
    fn truncation_drops_gust() {
        let mut conditions = base_conditions();
        conditions.wind_speed_mps_tenths = 12_000;
        conditions.wind_gust_mps_tenths = 25_000;
        let lines = format_display(&conditions);
        assert!(!lines.line1.contains('G'));
        assert_length(&lines);
    }

    #[test]
    fn truncation_drops_redundant_visibility() {
        let mut conditions = base_conditions();
        conditions.precip_kind = 5;
        conditions.visibility_m = 7000;
        let lines = format_display(&conditions);
        assert!(!lines.line1.starts_with("V10 "));
        assert!(lines.line1.contains("FG"));
        assert_length(&lines);
    }

    #[test]
    fn line_lengths_never_exceed_limit() {
        let mut conditions = base_conditions();
        conditions.precip_kind = 9;
        conditions.precip_intensity = 4;
        conditions.wind_speed_mps_tenths = 120;
        conditions.wind_gust_mps_tenths = 200;
        conditions.visibility_m = 1000;
        let lines = format_display(&conditions);
        assert_length(&lines);
    }
}
