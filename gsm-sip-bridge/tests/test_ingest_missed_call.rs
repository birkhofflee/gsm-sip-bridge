//! A VoWiFi/VoLTE agent's unanswered call raises the missed-call alert in the
//! daemon. Its own binary because `ingest::init_alerts` is a process-wide
//! `OnceLock`.

use gsm_sip_bridge::alerts::discord::DiscordClient;
use gsm_sip_bridge::config::secret::Secret;
use gsm_sip_bridge::config::AlertsConfig;
use gsm_sip_bridge::control::protocol::{
    AgentKind, AgentReport, AgentState, CallStatus, ObservedEvent,
};
use gsm_sip_bridge::metrics::ingest;
use std::time::Duration;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn report(seq: u64, status: CallStatus, caller: Option<&str>) -> AgentReport {
    AgentReport {
        agent: AgentKind::Ims,
        module_id: "test-missed-call".to_string(),
        epoch: 1,
        seq,
        state: AgentState::default(),
        events: vec![ObservedEvent::CallCompleted {
            status,
            duration_seconds: 0.0,
            caller: caller.map(str::to_string),
        }],
        dropped: 0,
        details: None,
    }
}

#[tokio::test]
async fn only_a_missed_call_is_alerted_and_it_names_the_caller() {
    let server = MockServer::start().await;
    let mut cfg = AlertsConfig::default();
    cfg.missed_call.enabled = true;
    cfg.default_webhook_url = Secret::new(format!("{}/webhook", server.uri()));
    ingest::init_alerts(
        cfg,
        DiscordClient::new(Secret::new(String::new()), "test".to_string()).unwrap(),
        std::collections::HashMap::new(),
    );

    Mock::given(method("POST"))
        .and(path("/webhook"))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;

    ingest::apply_report(&report(1, CallStatus::Answered, None));
    ingest::apply_report(&report(2, CallStatus::Failed, Some("+919000000001")));
    ingest::apply_report(&report(3, CallStatus::Missed, Some("+919000000001")));
    tokio::time::sleep(Duration::from_millis(500)).await;
    server.verify().await;

    let requests = server.received_requests().await.unwrap();
    let body = String::from_utf8_lossy(&requests[0].body);
    assert!(body.contains("Missed Call"), "{body}");
    assert!(
        body.contains("call from +919000000001 was never answered"),
        "{body}"
    );
}
