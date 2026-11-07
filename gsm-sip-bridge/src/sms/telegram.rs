//! Posts SMS notifications to a Telegram chat through the Bot API.
//!
//! The Bot API carries its token in the URL path, so the request URL is held
//! as a [`Secret`] and every error from the shared POST loop has its URL
//! stripped before it can reach a log (`post_json_with_retry`).

use crate::alerts::discord::{post_json_with_retry, PostError};
use crate::config::secret::Secret;
use crate::error::{BridgeError, BridgeResult};
use std::time::Duration;

const API_BASE: &str = "https://api.telegram.org";
const USER_AGENT: &str = "gsm-sip-bridge";
/// `sendMessage`'s limit on `text`. Counted in UTF-16 code units here, which is
/// never less than the character count, so the limit holds however it is read.
const MAX_TEXT_LEN: usize = 4096;
/// Long enough for any real sender. A longer one must not crowd out the body.
const MAX_SENDER_LEN: usize = 128;

#[derive(Clone)]
pub struct TelegramClient {
    client: reqwest::Client,
    send_message_url: Secret<String>,
    chat_id: String,
    instance: String,
}

impl TelegramClient {
    pub fn new(
        bot_token: &Secret<String>,
        chat_id: String,
        instance: String,
    ) -> BridgeResult<Self> {
        Self::with_api_base(API_BASE, bot_token, chat_id, instance)
    }

    /// [`Self::new`] against another server, for tests.
    pub fn with_api_base(
        api_base: &str,
        bot_token: &Secret<String>,
        chat_id: String,
        instance: String,
    ) -> BridgeResult<Self> {
        let client = reqwest::Client::builder()
            .user_agent(USER_AGENT)
            .timeout(Duration::from_secs(10))
            // A redirect would send the request, token included, somewhere
            // other than the configured API.
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| BridgeError::Sms(format!("failed to build HTTP client: {e}")))?;
        Ok(Self {
            client,
            send_message_url: Secret::new(format!(
                "{api_base}/bot{}/sendMessage",
                bot_token.expose_secret()
            )),
            chat_id,
            instance,
        })
    }

    /// Same arguments and result as `DiscordClient::forward_sms`, so the retry
    /// bookkeeping does not depend on which service is configured.
    pub async fn forward_sms(
        &self,
        module_id: &str,
        sender: &str,
        body: &str,
        timestamp: &str,
        phone_number: Option<&str>,
        late: bool,
    ) -> Result<u16, PostError> {
        let text = render_text(
            module_id,
            sender,
            body,
            timestamp,
            phone_number,
            late,
            &self.instance,
        );
        // No `parse_mode`: an SMS is untrusted text, shown exactly as received.
        // No link preview: Telegram must not fetch a link from an unread text.
        let payload = serde_json::json!({
            "chat_id": self.chat_id,
            "text": text,
            "link_preview_options": { "is_disabled": true },
        });
        post_json_with_retry(
            &self.client,
            self.send_message_url.expose_secret(),
            payload,
            "Telegram",
        )
        .await
    }
}

fn render_text(
    module_id: &str,
    sender: &str,
    body: &str,
    timestamp: &str,
    phone_number: Option<&str>,
    late: bool,
    instance: &str,
) -> String {
    let sender = truncate_utf16(sender, MAX_SENDER_LEN);
    let prefix = if late { "[Late] " } else { "" };
    let head = format!("{prefix}SMS from {sender}\n\n");

    let phone = phone_number
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .unwrap_or(crate::alerts::UNKNOWN_IDENTITY);
    let mut tail = format!("\n\nLine: {module_id} · Phone: {phone}");
    if late {
        tail.push_str(&format!("\nOriginally received: {timestamp}"));
    }
    tail.push_str(&format!("\ngsm-sip-bridge · {instance}"));

    let used = head.encode_utf16().count() + tail.encode_utf16().count();
    let body = truncate_utf16(body, MAX_TEXT_LEN.saturating_sub(used));
    format!("{head}{body}{tail}")
}

/// `s` cut to at most `max` UTF-16 code units, ending in `…` when cut. Never
/// splits a character.
fn truncate_utf16(s: &str, max: usize) -> String {
    if s.encode_utf16().count() <= max {
        return s.to_string();
    }
    let mut out = String::new();
    let mut used = 1; // the ellipsis
    for c in s.chars() {
        used += c.len_utf16();
        if used > max {
            break;
        }
        out.push(c);
    }
    out.push('…');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(body: &str, late: bool) -> String {
        render_text(
            "ec20-33",
            "+919000000001",
            body,
            "2026-01-02T03:04:05Z",
            Some("+919000000000"),
            late,
            "bridge-01",
        )
    }

    #[test]
    fn a_fresh_text_names_sender_body_line_and_instance() {
        let text = render("hello", false);
        assert!(
            text.starts_with("SMS from +919000000001\n\nhello\n\n"),
            "{text}"
        );
        assert!(
            text.contains("Line: ec20-33 · Phone: +919000000000"),
            "{text}"
        );
        assert!(text.ends_with("gsm-sip-bridge · bridge-01"), "{text}");
        assert!(!text.contains("Originally received"), "{text}");
    }

    #[test]
    fn a_retried_text_is_marked_late_with_its_original_time() {
        let text = render("hello", true);
        assert!(text.starts_with("[Late] SMS from "), "{text}");
        assert!(
            text.contains("Originally received: 2026-01-02T03:04:05Z"),
            "{text}"
        );
    }

    #[test]
    fn a_missing_phone_renders_as_unknown() {
        for phone in [None, Some("   ")] {
            let text = render_text("m", "s", "b", "t", phone, false, "i");
            assert!(
                text.contains(&format!("Phone: {}", crate::alerts::UNKNOWN_IDENTITY)),
                "{text}"
            );
        }
    }

    #[test]
    fn an_oversized_body_is_cut_to_the_limit_on_a_character_boundary() {
        for unit in ["x", "訊", "👋"] {
            let text = render(&unit.repeat(5000), false);
            assert!(text.encode_utf16().count() <= MAX_TEXT_LEN, "{unit}");
            assert!(text.contains('…'), "{unit}");
            assert!(text.ends_with("gsm-sip-bridge · bridge-01"), "{unit}");
        }
    }

    #[test]
    fn an_oversized_sender_cannot_crowd_out_the_body() {
        let text = render_text("m", &"s".repeat(9000), "the body", "t", None, false, "i");
        assert!(text.contains("the body"), "{text}");
    }
}
