//! Critical alerts delivered over the Telegram Bot API, against a local
//! stand-in server.

use chrono::Utc;
use gsm_sip_bridge::alerts::discord::DiscordClient;
use gsm_sip_bridge::alerts::{
    deliver, AlertCategory, AlertOutcome, CriticalEvent, CriticalEventKind,
};
use gsm_sip_bridge::config::secret::Secret;
use gsm_sip_bridge::config::{AlertsConfig, TelegramTarget};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

const TOKEN: &str = "123456:AAFakeTokenForTests_-";

fn event(kind: CriticalEventKind) -> CriticalEvent {
    CriticalEvent {
        category: AlertCategory::RegistrationLoss,
        unit_id: Some("ec20-33".to_string()),
        description: "registration lost for 300s".to_string(),
        phone_number: None,
        at: Utc::now(),
        kind,
    }
}

fn config(server: &MockServer, enabled: bool) -> AlertsConfig {
    let mut cfg = AlertsConfig::default();
    cfg.registration_loss.enabled = enabled;
    // A Discord webhook too: Telegram must win, and nothing may go to Discord.
    cfg.default_webhook_url = Secret::new(format!("{}/discord", server.uri()));
    cfg.telegram = Some(TelegramTarget {
        bot_token: Secret::new(TOKEN.to_string()),
        chat_id: "1234".to_string(),
        api_base: server.uri(),
    });
    cfg
}

fn discord() -> DiscordClient {
    DiscordClient::new(Secret::new(String::new()), "bridge-01".to_string()).unwrap()
}

#[tokio::test]
async fn an_enabled_category_is_sent_to_telegram_and_not_discord() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/bot{TOKEN}/sendMessage")))
        .respond_with(ResponseTemplate::new(200))
        .expect(2)
        .mount(&server)
        .await;
    Mock::given(path("/discord"))
        .respond_with(ResponseTemplate::new(204))
        .expect(0)
        .mount(&server)
        .await;

    let cfg = config(&server, true);
    for kind in [CriticalEventKind::Failure, CriticalEventKind::Recovered] {
        assert_eq!(
            deliver(&discord(), &cfg, event(kind)).await,
            AlertOutcome::Sent(200)
        );
    }

    let requests = server.received_requests().await.unwrap();
    let texts: Vec<String> = requests
        .iter()
        .map(|r| {
            serde_json::from_slice::<serde_json::Value>(&r.body).unwrap()["text"]
                .as_str()
                .unwrap()
                .to_string()
        })
        .collect();
    assert!(
        texts[0].starts_with("Critical: IMS/SIP Registration Loss"),
        "{}",
        texts[0]
    );
    assert!(
        texts[1].starts_with("Recovered: IMS/SIP Registration Loss"),
        "{}",
        texts[1]
    );
    assert!(
        texts[0].contains("gsm-sip-bridge · bridge-01"),
        "{}",
        texts[0]
    );
}

#[tokio::test]
async fn a_disabled_category_sends_nothing() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200))
        .expect(0)
        .mount(&server)
        .await;

    let outcome = deliver(
        &discord(),
        &config(&server, false),
        event(CriticalEventKind::Failure),
    )
    .await;
    assert_eq!(outcome, AlertOutcome::Skipped);
}

#[tokio::test]
async fn a_rejected_alert_is_reported_as_failed() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(400))
        .mount(&server)
        .await;

    let outcome = deliver(
        &discord(),
        &config(&server, true),
        event(CriticalEventKind::Failure),
    )
    .await;
    assert!(matches!(outcome, AlertOutcome::Failed(_)), "{outcome:?}");
}
