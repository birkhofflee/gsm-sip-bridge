//! SMS delivery over the Telegram Bot API, against a local stand-in server:
//! the real `reqwest` client, retry loop, SQLite store and writer thread.

use gsm_sip_bridge::config::secret::Secret;
use gsm_sip_bridge::config::SmsConfig;
use gsm_sip_bridge::sms::discord::PostError;
use gsm_sip_bridge::sms::retry::{self, SmsForwarder};
use gsm_sip_bridge::sms::telegram::TelegramClient;
use gsm_sip_bridge::store::schema::init_schema;
use gsm_sip_bridge::store::sms::{insert_sms, SmsRecord};
use gsm_sip_bridge::store::Transport;
use rusqlite::Connection;
use std::collections::HashMap;
use std::time::Duration;
use wiremock::matchers::{body_partial_json, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

const TOKEN: &str = "123456:AAFakeTokenForTests_-";

fn client(base: &str) -> TelegramClient {
    TelegramClient::with_api_base(
        base,
        &Secret::new(TOKEN.to_string()),
        "-1001234".to_string(),
        "test".to_string(),
    )
    .unwrap()
}

async fn send(c: &TelegramClient) -> Result<u16, PostError> {
    c.forward_sms(
        "ec20-33",
        "+919000000001",
        "<b>hi</b> *there*",
        "2026-01-02T03:04:05Z",
        Some("+919000000000"),
        false,
    )
    .await
}

#[tokio::test]
async fn posts_plain_text_to_the_tokens_send_message_endpoint() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/bot{TOKEN}/sendMessage")))
        .and(body_partial_json(serde_json::json!({
            "chat_id": "-1001234",
            "link_preview_options": { "is_disabled": true },
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
        .expect(1)
        .mount(&server)
        .await;

    assert_eq!(send(&client(&server.uri())).await, Ok(200));

    let requests = server.received_requests().await.unwrap();
    let body: serde_json::Value = serde_json::from_slice(&requests[0].body).unwrap();
    let text = body["text"].as_str().unwrap();
    assert!(
        text.contains("<b>hi</b> *there*"),
        "body kept verbatim: {text}"
    );
    assert!(
        body.get("parse_mode").is_none(),
        "an SMS must not be parsed as markup"
    );
}

#[tokio::test]
async fn a_rejected_message_is_not_retried() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(403).set_body_json(serde_json::json!({
            "ok": false, "error_code": 403,
            "description": "Forbidden: bot was blocked by the user",
        })))
        .expect(1)
        .mount(&server)
        .await;

    assert_eq!(
        send(&client(&server.uri())).await,
        Err(PostError::Rejected(403))
    );
}

#[tokio::test]
async fn a_long_rate_limit_in_the_body_is_reported_without_sleeping_it_out() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(429).set_body_json(serde_json::json!({
            "ok": false, "error_code": 429,
            "parameters": { "retry_after": 120 },
        })))
        .expect(1)
        .mount(&server)
        .await;

    assert_eq!(
        send(&client(&server.uri())).await,
        Err(PostError::RateLimited {
            retry_after: Duration::from_secs(120)
        })
    );
}

#[tokio::test]
async fn a_short_rate_limit_is_waited_out_and_retried() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(429).set_body_json(serde_json::json!({
            "parameters": { "retry_after": 0 },
        })))
        .up_to_n_times(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200))
        .mount(&server)
        .await;

    assert_eq!(send(&client(&server.uri())).await, Ok(200));
}

/// The token is in the URL, and `reqwest` puts the URL in its errors.
#[tokio::test]
async fn a_network_error_does_not_expose_the_token() {
    // Bound, then released: nothing is listening on this port any more.
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let err = send(&client(&format!("http://127.0.0.1:{port}")))
        .await
        .unwrap_err();

    assert!(matches!(err, PostError::Unreachable(_)), "{err:?}");
    for shown in [err.to_string(), format!("{err:?}"), err.category()] {
        assert!(!shown.contains(TOKEN), "token leaked: {shown}");
        assert!(!shown.contains("AAFake"), "token leaked: {shown}");
    }
}

#[tokio::test]
async fn a_redirect_is_not_followed() {
    let server = MockServer::start().await;
    let elsewhere = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200))
        .expect(0)
        .mount(&elsewhere)
        .await;
    Mock::given(method("POST"))
        .respond_with(
            ResponseTemplate::new(307)
                .insert_header("location", format!("{}/stolen", elsewhere.uri())),
        )
        .mount(&server)
        .await;

    let err = send(&client(&server.uri())).await.unwrap_err();
    assert_eq!(err, PostError::ServerError(307));
}

#[tokio::test]
async fn the_retry_sweep_delivers_a_failed_text_through_telegram() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("store.db");
    let conn = Connection::open(&db).unwrap();
    init_schema(&conn).unwrap();
    insert_sms(
        &conn,
        &SmsRecord {
            module_id: "ec20-33".into(),
            sender: "+919000000001".into(),
            body: "late text".into(),
            received_at: chrono::Utc::now().to_rfc3339(),
            forwarding_status: "failed".into(),
            transport: Transport::Vowifi,
            retry_eligible: true,
        },
    )
    .unwrap();
    conn.execute("UPDATE sms SET claimed_until = NULL", [])
        .unwrap();

    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/bot{TOKEN}/sendMessage")))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&server)
        .await;

    let cfg = SmsConfig {
        enabled: true,
        discord_webhook_url: Secret::new(String::new()),
        telegram_bot_token: Secret::new(TOKEN.to_string()),
        telegram_chat_id: "-1001234".into(),
        db_path: db.to_string_lossy().into_owned(),
        retry_enabled: true,
        retry_interval_sec: 3600,
        retry_max_age_sec: 86_400,
    };
    let fwd = SmsForwarder::new(client(&server.uri()), &cfg, HashMap::new());

    let out = retry::sweep(&fwd, &None).await;
    assert_eq!((out.attempted, out.delivered), (1, 1));

    let requests = server.received_requests().await.unwrap();
    let body: serde_json::Value = serde_json::from_slice(&requests[0].body).unwrap();
    assert!(body["text"]
        .as_str()
        .unwrap()
        .starts_with("[Late] SMS from "));
    let status: String = conn
        .query_row("SELECT forwarding_status FROM sms", [], |r| r.get(0))
        .unwrap();
    assert_eq!(status, "sent");
}
