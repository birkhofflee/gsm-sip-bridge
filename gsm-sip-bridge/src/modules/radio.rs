//! Where the bridge leaves a modem's radio when it power-cycles the SIM.
//!
//! VoWiFi needs the modem only for its SIM: the tunnel and IMS run over the
//! host's own network. With `[vowifi].modem_flight_mode`, the radio is kept
//! off (`AT+CFUN=4`, the SIM stays powered) so the modem never attaches to a
//! cellular network. While roaming, an attached modem can be paged for a call
//! the carrier failed to deliver over VoWiFi, and carries a data context on
//! the visited network.

use crate::config::AppConfig;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RadioPolicy {
    /// `AT+CFUN=1`: full functionality, as before this setting existed.
    #[default]
    On,
    /// `AT+CFUN=4`: radio off, SIM on.
    FlightMode,
}

impl RadioPolicy {
    pub fn from_config(config: &AppConfig) -> Self {
        if config.vowifi.modem_flight_mode {
            Self::FlightMode
        } else {
            Self::On
        }
    }

    /// The `AT+CFUN` level this policy keeps the modem at.
    pub fn cfun_level(self) -> u8 {
        match self {
            Self::On => 1,
            Self::FlightMode => 4,
        }
    }

    /// The command that brings the modem back up to that level.
    pub fn cfun_command(self) -> &'static str {
        match self {
            Self::On => "AT+CFUN=1",
            Self::FlightMode => "AT+CFUN=4",
        }
    }

    /// A SIM power cycle: the SIM is powered down with the radio, then back
    /// up to this policy's level. Shared by every recovery that cycles the
    /// SIM, so none of them can leave the radio on in flight mode.
    pub fn sim_power_cycle(self) -> [&'static str; 2] {
        ["AT+CFUN=0", self.cfun_command()]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sim_power_cycle_ends_at_the_policys_level() {
        assert_eq!(
            RadioPolicy::On.sim_power_cycle(),
            ["AT+CFUN=0", "AT+CFUN=1"]
        );
        assert_eq!(
            RadioPolicy::FlightMode.sim_power_cycle(),
            ["AT+CFUN=0", "AT+CFUN=4"]
        );
        assert_eq!(RadioPolicy::FlightMode.cfun_level(), 4);
        assert_eq!(RadioPolicy::default(), RadioPolicy::On);
    }
}
