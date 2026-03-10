use crate::display::DisplayLines;

/// Maximum characters per line supported by the Block 1 display.
const MAX_LCD_LINE_LEN: usize = 16;

/// Errors returned by the simple display interface layer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DisplayError {
    /// A supplied line exceeds the 16-character hardware constraint.
    LineTooLong { line_index: usize, length: usize },
}

impl DisplayError {
    fn ensure_line_length(line: &str, line_index: usize) -> Result<(), DisplayError> {
        let length = line.len();
        if length <= MAX_LCD_LINE_LEN {
            Ok(())
        } else {
            Err(DisplayError::LineTooLong { line_index, length })
        }
    }
}

/// Marker trait for 16x2 text displays.
///
/// The interface accepts already-formatted lines and does **not** modify their content.
pub trait TextDisplay {
    /// Renders a pair of 16-character lines.
    fn render(&mut self, lines: &DisplayLines) -> Result<(), DisplayError>;
}

/// Displays that expose logged entries for runtime inspection.
pub trait LoggableDisplay {
    fn drain_logs(&mut self) -> Vec<String>;
}

/// Dummy display implementation used by unit tests and future integration.
#[derive(Debug, Default)]
pub struct MockDisplay {
    latest_lines: Option<DisplayLines>,
}

impl MockDisplay {
    /// Creates a new mock display.
    pub fn new() -> Self {
        Self { latest_lines: None }
    }

    /// Returns the most recently rendered lines, if any.
    pub fn latest_lines(&self) -> Option<&DisplayLines> {
        self.latest_lines.as_ref()
    }
}

impl TextDisplay for MockDisplay {
    fn render(&mut self, lines: &DisplayLines) -> Result<(), DisplayError> {
        DisplayError::ensure_line_length(&lines.line1, 1)?;
        DisplayError::ensure_line_length(&lines.line2, 2)?;
        self.latest_lines = Some(lines.clone());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{DisplayError, MockDisplay, TextDisplay};
    use crate::display::{format_display, DisplayLines};
    use crate::interpolation::EstimatedLocalConditions;

    fn sample_conditions() -> EstimatedLocalConditions {
        EstimatedLocalConditions {
            air_temp_c_tenths: 500,
            wind_speed_mps_tenths: 80,
            wind_gust_mps_tenths: 120,
            precip_prob_pct: 50,
            precip_kind: 1,
            precip_intensity: 2,
            visibility_m: 5000,
            hazard_flags: 0,
            confidence_score: 85,
        }
    }

    #[test]
    fn renders_two_valid_lines() {
        let mut display = MockDisplay::new();
        let lines = DisplayLines {
            line1: "V5 RA W8".to_string(),
            line2: "RAIN  C80%".to_string(),
        };

        assert!(display.render(&lines).is_ok());
        assert_eq!(display.latest_lines(), Some(&lines));
    }

    #[test]
    fn rejects_overlength_lines() {
        let mut display = MockDisplay::new();
        let lines = DisplayLines {
            line1: "12345678901234567".to_string(),
            line2: "RAIN  C80%".to_string(),
        };

        let err = display.render(&lines).unwrap_err();
        assert!(matches!(
            err,
            DisplayError::LineTooLong { line_index: 1, .. }
        ));
        assert!(display.latest_lines().is_none());
    }

    #[test]
    fn accepts_formatted_display_output() {
        let mut display = MockDisplay::new();
        let lines = format_display(&sample_conditions());
        assert!(display.render(&lines).is_ok());
        assert_eq!(display.latest_lines(), Some(&lines));
    }

    #[test]
    fn stores_latest_lines_after_multiple_writes() {
        let mut display = MockDisplay::new();
        let first = DisplayLines {
            line1: "V5 RA W8".to_string(),
            line2: "RAIN  C80%".to_string(),
        };
        let second = DisplayLines {
            line1: "FG W5".to_string(),
            line2: "FOG   C70%".to_string(),
        };

        display.render(&first).unwrap();
        display.render(&second).unwrap();
        assert_eq!(display.latest_lines(), Some(&second));
    }
}
